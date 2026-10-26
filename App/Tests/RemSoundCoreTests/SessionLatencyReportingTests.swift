import Foundation
import RemSoundJam
import XCTest
@testable import RemSoundCore

final class SessionLatencyReportingTests: XCTestCase {
    private let password="isolated lane reporting secret"
    private func start(_ session:Session,peer:String="",send:Bool=false,plugins:Bool=false) {
        let ready=expectation(description:"isolated lane worker")
        session.start(password:password,peerAddress:peer,send:send,receive:false,plugins:plugins,
            name:"Lane fixture",sendCodec:.pcm,completion:{ receipt in XCTAssertEqual(receipt?.running,true);ready.fulfill() })
        wait(for:[ready],timeout:3)
    }
    func testActualPeriodicReportKeepsEachAdmittedStreamsCaptureAndUnknownOutput() throws {
        let peer=try UDP(port:0,loopback:true),session=Session(testPeerPort:peer.boundPort)
        defer { session.shutdown();XCTAssertEqual(session.testPorts.audio,0);withExtendedLifetime(peer) {} }
        start(session)
        let endpoint=Endpoint("127.0.0.1",peer.boundPort)
        session.testSelectResolvedDirectPeer(name:"Fixture",endpoint:endpoint)
        let key=try Credentials(password:password)
        for (stream,capture) in [(UInt16(3),3.5),(UInt16(4),12.0)] {
            let format=StreamFormat.pcm(key.fingerprint).capturing(milliseconds:capture)
            session.testPeerPacket(Wire.packet(.format,stream:stream,payload:format.encode()),from:endpoint)
        }
        let original=session.testProtocolStreamReceipts().map { $0.0 }
        let wrong=StreamFormat.pcm(Data(repeating:0,count:8)).capturing(milliseconds:999)
        session.testPeerPacket(Wire.packet(.format,stream:3,payload:wrong.encode()),from:endpoint)
        XCTAssertEqual(session.testProtocolStreamReceipts().map { $0.0 },original)
        let root=try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])
        // Every second kept, so the readings file has this second's journeys straight away (the observations column).
        let file=JamLog(directory:URL(fileURLWithPath:root).appendingPathComponent("latency-\(UUID())"),prefix:"latency",everySecond:true)
        session.testServerStatusLog(file)
        var text="";let deadline=ProcessInfo.processInfo.systemUptime+3
        while !text.contains("receive latency:"),ProcessInfo.processInfo.systemUptime<deadline {
            session.testFlushServerStatusLog()
            if let path=file.currentReadingsFile,let handle=try? FileHandle(forReadingFrom:path) {
                let bytes=try handle.read(upToCount:256*1024) ?? Data();try handle.close()
                text=String(decoding:bytes,as:UTF8.self)
            }
            if !text.contains("receive latency:") { Thread.sleep(forTimeInterval:0.005) }
        }
        XCTAssertTrue(text.contains("receive latency:"),"actual once-per-second reporter ran")
        XCTAssertTrue(text.contains("capture component 3.500 ms"))
        XCTAssertTrue(text.contains("capture component 12.000 ms"))
        XCTAssertTrue(text.contains("complete sum unavailable"))
        XCTAssertFalse(text.contains("capture component 999.000 ms"))
        XCTAssertFalse(text.contains(password))
    }
    func testActualPluginFormatUsesItsFreshHostBlockRatherThanAnInputDevice() throws {
        let peer=try UDP(port:0,loopback:true),plugin=try UDP(port:0,loopback:true)
        let session=Session(testPeerPort:peer.boundPort)
        defer { session.shutdown();XCTAssertEqual(session.testPorts.audio,0);withExtendedLifetime((peer,plugin)) {} }
        start(session,peer:"127.0.0.1",send:true,plugins:true)
        let endpoint=Endpoint("127.0.0.1",plugin.boundPort)
        var pid=Data();pid.put(UInt32(12345))
        session.testWebBridgePacket(Bridge.encode(.hello,instance:17,payload:pid),from:endpoint)
        var geometry=Data();geometry.put(Double(48_000).bitPattern);geometry.put(UInt32(256))
        session.testWebBridgePacket(Bridge.encode(.hostCallback,instance:17,payload:geometry),from:endpoint)
        var audio=Data();for _ in 0..<512 { audio.put(Float(0.25).bitPattern) }
        session.testWebBridgePacket(Bridge.encode(.trackAudio,instance:17,payload:audio),from:endpoint)
        let deadline=ProcessInfo.processInfo.systemUptime+2;var format:StreamFormat?
        while format == nil,ProcessInfo.processInfo.systemUptime<deadline {
            if let (bytes,_)=peer.receive(),let packet=Wire.parse(bytes),packet.kind == .format { format=StreamFormat.parse(packet.payload) }
            else { Thread.sleep(forTimeInterval:0.001) }
        }
        XCTAssertEqual(try XCTUnwrap(format).captureLatencyMs,5.3,accuracy:0.001)
        func nextFormat() throws -> StreamFormat {
            let until=ProcessInfo.processInfo.systemUptime+2
            while ProcessInfo.processInfo.systemUptime<until {
                if let (bytes,_)=peer.receive(),let packet=Wire.parse(bytes),packet.kind == .format,
                   let value=StreamFormat.parse(packet.payload) { return value }
                Thread.sleep(forTimeInterval:0.001)
            }
            XCTFail("actual plugin metadata refresh missing");throw NSError(domain:"fixture",code:1)
        }
        geometry=Data();geometry.put(Double(48_000).bitPattern);geometry.put(UInt32(128))
        session.testWebBridgePacket(Bridge.encode(.hostCallback,instance:17,payload:geometry),from:endpoint)
        session.testWebBridgePacket(Bridge.encode(.trackAudio,instance:17,payload:audio),from:endpoint)
        XCTAssertEqual(try nextFormat().captureLatencyMs,2.7,accuracy:0.001,"changed geometry must not wait for the periodic format refresh")
        Thread.sleep(forTimeInterval:3.05)
        session.testWebBridgePacket(Bridge.encode(.trackAudio,instance:17,payload:audio),from:endpoint)
        XCTAssertEqual(try nextFormat().captureLatencyMs,0,"stale geometry cannot remain an announced capture component")
    }
    func testNamedLatencySlicesRunRealChecksButRetainTheirRemainingAcceptanceGaps() throws {
        for name in ["Latency estimate counts every stage (no silently-missing term)",
            "CAPTURE DELAY PER LANE: each lane's format says its own capture, and the far end's readout counts the right one per output"] {
            let report=ProductTestPack.run(pack:.feature,only:name)
            let step=try XCTUnwrap(report.steps.first)
            XCTAssertEqual(step.status,"UNVERIFIED");XCTAssertGreaterThan(step.assertions,10)
            XCTAssertFalse(step.failures.contains("missing-product-check"));XCTAssertEqual(report.exitCode,1)
        }
    }
    func testActualReportFormulaKeepsOutputsAndStreamsCorrelatedAndUnknownStagesExplicit() {
        let format=StreamFormat.opus(Data(repeating:1,count:8),frames:120).capturing(milliseconds:8)
        let fast=PeerLatencyReport(format:format,queuedFrames:480,rttMs:24,outputMs:2)
        let slow=PeerLatencyReport(format:format,queuedFrames:480,rttMs:24,outputMs:22)
        XCTAssertEqual(fast.totalMs,34.5);XCTAssertEqual(slow.totalMs,54.5)
        XCTAssertEqual(PeerLatencyReport.maximumComplete([fast,slow]),54.5)
        let unknown=PeerLatencyReport(format:format.capturing(milliseconds:0),queuedFrames:480,rttMs:24,outputMs:nil)
        XCTAssertNil(unknown.totalMs);XCTAssertEqual(unknown.knownSubtotalMs,24.5)
        XCTAssertNil(PeerLatencyReport.maximumComplete([fast,unknown]))
        XCTAssertNil(PeerLatencyReport.maximumComplete([]))
        XCTAssertTrue(unknown.logDescription.contains("output presentation not measured"))
        XCTAssertTrue(unknown.logDescription.contains("complete sum unavailable"))
    }
}
