import CryptoKit
import Foundation
import XCTest
@testable import RemSoundCore

final class SessionProtocolCompatibilityTests: XCTestCase {
    private let password="synthetic protocol239"
    private func start(_ session:Session) {
        let ready=expectation(description:"isolated protocol worker")
        session.onChange={ view in guard view.running else { return };session.onChange=nil;ready.fulfill() }
        session.start(password:password,peerAddress:"",send:false,receive:false,plugins:false,name:"Private protocol fixture")
        wait(for:[ready],timeout:3)
    }
    private func fixture() throws -> (Session,UDP,Endpoint) {
        let socket=try UDP(port:0,loopback:true)
        let endpoint=Endpoint("127.0.0.1",socket.boundPort)
        let session=Session(testPeerPort:socket.boundPort);start(session)
        session.testSelectResolvedDirectPeer(name:"Fixture",endpoint:endpoint)
        return (session,socket,endpoint)
    }
    func testLegacyAndWrongFingerprintCannotOpenAudioButAuthenticatedFormatCan() throws {
        let (session,socket,endpoint)=try fixture();defer { session.shutdown();XCTAssertEqual(session.testPorts.audio,0);withExtendedLifetime(socket) {} }
        let credentials=try Credentials(password:password),bytes=StreamFormat.pcm(credentials.fingerprint).encode()
        for count in [32,36] {
            session.testPeerPacket(Wire.packet(.format,stream:3,payload:Data(bytes.prefix(count))),from:endpoint)
            XCTAssertTrue(session.testProtocolStreamReceipts().isEmpty)
        }
        session.testPeerPacket(Wire.packet(.format,stream:3,payload:StreamFormat.pcm(Data(repeating:0,count:8)).encode()),from:endpoint)
        XCTAssertTrue(session.testProtocolStreamReceipts().isEmpty)
        session.testPeerPacket(Wire.packet(.format,stream:3,payload:bytes),from:endpoint)
        let current=try XCTUnwrap(session.testProtocolStreamReceipts().first)
        XCTAssertEqual(session.testProtocolStreamReceipts().count,1)
        session.testPeerPacket(Wire.packet(.format,stream:3,payload:StreamFormat.pcm(Data(repeating:0,count:8)).encode()),from:endpoint)
        let after=try XCTUnwrap(session.testProtocolStreamReceipts().first)
        XCTAssertEqual(after.0,current.0);XCTAssertEqual(after.1.fingerprint,credentials.fingerprint)
    }
    func testCaptureMetadataRefreshRetainsActualDecoderAndAuthenticatedStream() throws {
        let (session,socket,endpoint)=try fixture();defer { session.shutdown();XCTAssertEqual(session.testPorts.audio,0);withExtendedLifetime(socket) {} }
        let credentials=try Credentials(password:password)
        var bytes=StreamFormat.pcm(credentials.fingerprint).encode()
        session.testPeerPacket(Wire.packet(.format,stream:3,payload:bytes),from:endpoint)
        let first=try XCTUnwrap(session.testProtocolStreamReceipts().first)
        bytes[44]=35
        session.testPeerPacket(Wire.packet(.format,stream:3,payload:bytes),from:endpoint)
        let second=try XCTUnwrap(session.testProtocolStreamReceipts().first)
        XCTAssertEqual(first.0,second.0)
        XCTAssertEqual(second.1.encode()[44],35)
    }
    func testActualHeartbeatDispatchEchoesExactTickStreamAndSequence() throws {
        let (session,socket,endpoint)=try fixture();defer { session.shutdown();XCTAssertEqual(session.testPorts.audio,0);withExtendedLifetime(socket) {} }
        let ping=Data([0,8,7,6,5,4,3,2,1])
        session.testPeerPacket(Wire.packet(.heartbeat,stream:0x1234,sequence:0x4455,payload:ping),from:endpoint)
        let deadline=ProcessInfo.processInfo.systemUptime+2;var reply:Wire.Packet?
        while reply == nil,ProcessInfo.processInfo.systemUptime < deadline {
            if let bytes=socket.receive()?.0,let packet=Wire.parse(bytes),packet.kind == .heartbeat,packet.sequence == 0x4455 { reply=packet }
            else { RunLoop.current.run(until:Date().addingTimeInterval(0.001)) }
        }
        let packet=try XCTUnwrap(reply)
        XCTAssertEqual(packet.stream,0x1234)
        XCTAssertEqual(Data(packet.payload.prefix(9)),Data([1,8,7,6,5,4,3,2,1]))
    }
    func testActualTickDispatchPreservesAuthenticationSkewAndNonceFences() throws {
        let (session,socket,endpoint)=try fixture();defer { session.shutdown();XCTAssertEqual(session.testPorts.audio,0);withExtendedLifetime(socket) {} }
        let key=try Credentials(password:password),wrong=try Credentials(password:"different synthetic")
        let now=Int64(Date().timeIntervalSince1970),first=UUID(),second=UUID()
        session.testPeerPacket(try wrong.tick(id:first,now:now,sequence:1),from:endpoint)
        session.testPeerPacket(try key.tick(id:first,now:now-601,sequence:2),from:endpoint)
        XCTAssertTrue(session.testVerifiedPeerIdentities().isEmpty)
        let nonce=try AES.GCM.Nonce(data:Data(1...12))
        func seal(_ id:UUID) throws -> Data {
            var plain=Data([1]);plain.put(now);var uuid=id.uuid
            withUnsafeBytes(of:&uuid) { plain.append(contentsOf:$0) }
            let box=try AES.GCM.seal(plain,using:key.key,nonce:nonce)
            let payload=nonce.withUnsafeBytes { Data($0) }+box.tag+box.ciphertext
            return Wire.packet(.tickProof,stream:0xffff,sequence:3,payload:payload)
        }
        session.testPeerPacket(try seal(first),from:endpoint)
        XCTAssertEqual(session.testVerifiedPeerIdentities()[endpoint.address],first)
        session.testPeerPacket(try seal(second),from:endpoint)
        XCTAssertEqual(session.testVerifiedPeerIdentities()[endpoint.address],first)
    }
    func testUnselectedAuthenticatedTickStillCannotVerifyPeer() throws {
        let socket=try UDP(port:0,loopback:true),session=Session(testPeerPort:0)
        defer { session.shutdown();XCTAssertEqual(session.testPorts.audio,0);withExtendedLifetime(socket) {} }
        start(session)
        let endpoint=Endpoint("127.0.0.1",socket.boundPort),id=UUID(),key=try Credentials(password:password)
        let packet=try key.tick(id:id,now:Int64(Date().timeIntervalSince1970),sequence:1)
        session.testPeerPacket(packet,from:endpoint);XCTAssertTrue(session.testVerifiedPeerIdentities().isEmpty)
        session.testSelectResolvedDirectPeer(name:"Fixture",endpoint:endpoint)
        session.testPeerPacket(packet,from:endpoint)
        XCTAssertTrue(session.testVerifiedPeerIdentities().isEmpty, "The incoming-peer prompt already consumed this proof nonce")
        session.testPeerPacket(try key.tick(id:id,now:Int64(Date().timeIntervalSince1970),sequence:2),from:endpoint)
        XCTAssertEqual(session.testVerifiedPeerIdentities()[endpoint.address],id)
    }
}
