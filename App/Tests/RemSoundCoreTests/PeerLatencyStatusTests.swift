import Foundation
import XCTest
@testable import RemSoundCore

final class PeerLatencyStatusTests: XCTestCase {
    private func summary(capture:Double=3,rtt:Double?=20,outputs:[Double?]=[5],streams:Int=1) -> PeerLatencyReport.Summary {
        let format=StreamFormat.opus(Data(repeating:1,count:8),frames:120).capturing(milliseconds:capture)
        return .init(inputs:(0..<streams).map { .init(stream:String($0),format:format,queuedFrames:480) },outputs:outputs,rttMs:rtt)
    }
    func testRoundStableFiveMillisecondValuesKeepOutputsSeparate() {
        XCTAssertEqual(summary(capture:3.1).status,summary(capture:3.2).status)
        XCTAssertNotEqual(summary(capture:3.1).status,summary(capture:8).status)
        let both=summary(outputs:[5,25]).status
        XCTAssertTrue(both.contains("total latency about 30 ms on Core Audio output 1"))
        XCTAssertTrue(both.contains("total latency about 50 ms on Core Audio output 2"))
        XCTAssertFalse(both.contains("ASIO"));XCTAssertFalse(both.contains("WASAPI"))
    }
    func testQuietUnknownAndTruncatedJourneysNeverBecomeGuessedTotals() {
        XCTAssertEqual(summary(streams:0).status,"ping 20 ms")
        XCTAssertEqual(summary(rtt:nil,streams:0).status,"ping unknown")
        XCTAssertTrue(summary(capture:0,outputs:[nil]).status.contains("capture not stated"))
        XCTAssertTrue(summary(capture:0,outputs:[nil]).status.contains("output not measured"))
        XCTAssertFalse(summary(capture:0).status.contains("total latency about"))
        let full=summary(streams:65)
        XCTAssertEqual(full.journeys.count,64);XCTAssertTrue(full.truncated)
        XCTAssertNil(full.maximumCompleteMs)
        XCTAssertTrue(full.status.contains("additional journeys omitted"))
        XCTAssertEqual(summary(rtt:.infinity,streams:0).status,"ping unknown")
        XCTAssertEqual(summary(rtt:Double.greatestFiniteMagnitude,streams:0).status,"ping unknown")
    }
    func testActualPublishedStatusUsesOwnedPongAndEachFixtureOutputValue() throws {
        let peer=try UDP(port:0,loopback:true)
        let session=Session(testPeerPort:peer.boundPort,testOutputPresentationsMs:[5,25])
        defer {session.onChange=nil;session.shutdown();XCTAssertEqual(session.testPorts.audio,0);withExtendedLifetime(peer){}}
        let started=expectation(description:"owned output-value status worker")
        var latest:PeerView?
        session.onChange={view in latest=view.peers.first}
        session.start(password:"isolated paired status",peerAddress:"",send:false,receive:false,plugins:false,
            name:"Status",completion:{_ in started.fulfill()})
        wait(for:[started],timeout:3)
        let endpoint=Endpoint("127.0.0.1",peer.boundPort)
        session.testSelectResolvedDirectPeer(name:"Actual",endpoint:endpoint)
        let key=try Credentials(password:"isolated paired status")
        let format=Wire.packet(.format,stream:7,payload:StreamFormat.opus(key.fingerprint,frames:120).capturing(milliseconds:3).encode())
        let deadline=ProcessInfo.processInfo.systemUptime+5
        var replied=false,nextFormat=0.0
        while !(latest?.status.contains("total latency about")==true && replied),ProcessInfo.processInfo.systemUptime<deadline {
            if ProcessInfo.processInfo.systemUptime>=nextFormat {
                session.testPeerPacket(format,from:endpoint);nextFormat=ProcessInfo.processInfo.systemUptime+0.3
            }
            while let (bytes,_)=peer.receive() {
                guard let packet=Wire.parse(bytes),packet.kind == .heartbeat,
                    HeartbeatPayload.parse(packet.payload)?.kind == .ping else {continue}
                var pong=packet.payload;pong[0]=1
                peer.send(Wire.packet(.heartbeat,stream:packet.stream,sequence:packet.sequence,payload:pong),to:Endpoint("127.0.0.1",session.testPorts.audio))
                replied=true
            }
            RunLoop.main.run(until:Date().addingTimeInterval(0.005))
        }
        XCTAssertTrue(replied);XCTAssertEqual(latest?.name,"Actual")
        XCTAssertTrue(latest?.status.contains("total latency about")==true)
        XCTAssertTrue(latest?.status.contains("Core Audio output 1")==true)
        XCTAssertTrue(latest?.status.contains("Core Audio output 2")==true)
        XCTAssertFalse(latest?.status.contains("ping unknown")==true)
    }
    func testActualPublishedPeerStatusShowsUnknownStagesWithoutInventingATotal() throws {
        let peer=try UDP(port:0,loopback:true),session=Session(testPeerPort:peer.boundPort)
        defer { session.onChange=nil;session.shutdown();XCTAssertEqual(session.testPorts.audio,0);withExtendedLifetime(peer) {} }
        let started=expectation(description:"owned status worker")
        var latest=""
        session.onChange={ view in latest=view.peers.first?.status ?? latest }
        session.start(password:"isolated status fixture",peerAddress:"",send:false,receive:false,plugins:false,
            name:"Status",completion:{ value in XCTAssertTrue(value?.running == true);started.fulfill() })
        wait(for:[started],timeout:3)
        let endpoint=Endpoint("127.0.0.1",peer.boundPort)
        session.testSelectResolvedDirectPeer(name:"Status peer",endpoint:endpoint)
        let key=try Credentials(password:"isolated status fixture")
        session.testPeerPacket(Wire.packet(.format,stream:3,payload:StreamFormat.opus(key.fingerprint,frames:120).capturing(milliseconds:3).encode()),from:endpoint)
        let deadline=ProcessInfo.processInfo.systemUptime+2.5
        while !latest.contains("total latency unavailable"),ProcessInfo.processInfo.systemUptime<deadline {
            RunLoop.main.run(until:Date().addingTimeInterval(0.005))
        }
        XCTAssertTrue(latest.contains("ping"));XCTAssertTrue(latest.contains("total latency unavailable"))
        XCTAssertTrue(latest.contains("output not measured"));XCTAssertFalse(latest.contains("total latency about"))
    }
    func testNamedPeerStatusSliceExecutesCurrentFormattingWithoutClaimingFullNativeAcceptance() throws {
        let name=try XCTUnwrap(ProductTestPack.names.first { $0.hasPrefix("PEER LATENCY:") })
        let report=ProductTestPack.run(pack:.feature,only:name)
        let step=try XCTUnwrap(report.steps.first)
        XCTAssertEqual(step.status,"UNVERIFIED");XCTAssertGreaterThan(step.assertions,12)
        XCTAssertFalse(step.failures.contains("missing-product-check"));XCTAssertEqual(report.exitCode,1)
    }
}
