import Foundation
import XCTest
@testable import RemSoundCore

final class SessionPCM24Tests: XCTestCase {
    func testActualSenderAndAuthenticatedDecoderUseGoldenStereoPCM24() throws {
        let peer=try UDP(port:0,loopback:true)
        let session=Session(testPeerPort:peer.boundPort,testCapturePushDriven:true)
        defer { session.shutdown();withExtendedLifetime(peer) {} }
        let ready=expectation(description:"owned sender running")
        session.onChange={ view in
            guard view.running else { return }
            session.onChange=nil;ready.fulfill()
        }
        let password="isolated PCM24 wire fixture"
        session.start(password:password,peerAddress:"127.0.0.1",send:true,
            receive:false,plugins:false,name:"PCM",sendCodec:.pcm)
        wait(for:[ready],timeout:3)
        var samples:[Float]=[]
        var golden=Data()
        for _ in 0..<Wire.pcmFrames {
            samples += [0.5,-0.25]
            golden.append(contentsOf:[0,0,64,0,0,224])
        }
        session.testCapture(samples)
        let until=ProcessInfo.processInfo.systemUptime+3
        var audio:Wire.Packet?
        while audio == nil && ProcessInfo.processInfo.systemUptime < until {
            while let (data,_)=peer.receive() {
                if let packet=Wire.parse(data),packet.kind == .audio { audio=packet }
            }
            if audio == nil { Thread.sleep(forTimeInterval:0.001) }
        }
        let packet=try XCTUnwrap(audio)
        XCTAssertEqual(packet.payload[4],0);XCTAssertEqual(packet.payload[5],1)
        let key=try Credentials(password:password)
        XCTAssertEqual(try key.open(Data(packet.payload.dropFirst(6))),golden,
            "Independent wire bytes verify the production Session encoder")
        let decoder=StreamDecoder(.pcm(key.fingerprint),jitterMs:0,smoothness:10)
        let wrong=try Credentials(password:"different isolated key")
        XCTAssertFalse(decoder.accept(packet,credentials:wrong));XCTAssertEqual(decoder.queuedFrames,0)
        XCTAssertTrue(decoder.accept(packet,credentials:key));XCTAssertEqual(decoder.queuedFrames,Wire.pcmFrames)
        let back=decoder.read(Wire.pcmFrames)
        XCTAssertEqual(back,samples,"Actual authenticated decoder preserves asymmetric stereo samples")
        session.shutdown();XCTAssertEqual(session.testPorts.audio,0)
    }
}
