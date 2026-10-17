import Foundation
import RemSoundJam
import XCTest
@testable import RemSoundCore

final class PlayoutRingProductTests: XCTestCase {
    private let capacity=PlayoutQueue.maximumBufferedMs*PlayoutQueue.rate/1000
    func testActualPlayoutOverflowRetainsTheNewestBoundedTailInOrder() {
        let queue=PlayoutQueue(jitterMs:0,packetFrames:233,now:0,smoothness:10,artifact:.click)
        queue.append(Array(repeating:0.25,count:capacity*2))
        queue.append(Array(repeating:-0.5,count:64*2))
        XCTAssertEqual(queue.queuedFrames,capacity)
        let got=queue.read(capacity,now:0,keepsInTime:false)
        XCTAssertTrue(got == Array(repeating:Float(0.25),count:(capacity-64)*2)+Array(repeating:Float(-0.5),count:64*2))
        XCTAssertEqual(queue.overflows,1)
    }
    func testOversizedDecodedWriteCannotExceedActualPlayoutBudget() {
        let queue=PlayoutQueue(jitterMs:0,packetFrames:233,now:0,smoothness:10,artifact:.click)
        var values=Array(repeating:Float(0.25),count:(capacity+17)*2)
        values.replaceSubrange(values.count-2..<values.count,with:[-0.5,0.5])
        queue.append(values)
        XCTAssertEqual(queue.queuedFrames,capacity)
        XCTAssertTrue(queue.read(capacity,now:0,keepsInTime:false) == Array(values.suffix(capacity*2)))
    }
    func testNamedProductRingCompletesActualCaptureAndReceiveRoleSemantics() throws {
        let report=ProductTestPack.run(pack:.feature,only:ProductTestPack.ringIntegrity)
        let step=try XCTUnwrap(report.steps.first)
        XCTAssertEqual(step.status,"PASS");XCTAssertTrue(step.failures.isEmpty)
        XCTAssertGreaterThan(step.assertions,40);XCTAssertEqual(report.exitCode,0)
    }
    func testConcealmentAndRestartRetainHonestLifetimeOverflowCounters() {
        let queue=PlayoutQueue(jitterMs:0,packetFrames:233,now:0,smoothness:10,artifact:.click)
        queue.appendConcealment(Array(repeating:0.25,count:(capacity+17)*2))
        XCTAssertEqual(queue.queuedFrames,capacity);XCTAssertEqual(queue.overflowDroppedFrames,17)
        XCTAssertFalse(queue.hasAudio)
        queue.reset(now:1)
        XCTAssertEqual(queue.queuedFrames,0);XCTAssertEqual(queue.overflowDroppedFrames,17)
        XCTAssertEqual(queue.overflows,1)
        queue.append([0.5,-0.5]);XCTAssertTrue(queue.read(1,now:1,keepsInTime:false)==[0.5,-0.5])
    }
    func testAuthenticatedDecoderOverflowRetainsNewestStereoFrames() throws {
        let key=try Credentials(password:"isolated playout cap")
        let decoder=StreamDecoder(.pcm(key.fingerprint),jitterMs:2,smoothness:10,artifact:.click)
        let packetFrames=Wire.pcmFrames
        var expected:[Float]=[]
        for index in 1...86 {
            let left:Float=index<=34 ? 0.25 : -0.5
            let right:Float = -left
            var raw=Data()
            for _ in 0..<packetFrames {
                raw.append(contentsOf:index<=34 ? [0,0,32,0,0,224] : [0,0,192,0,0,64])
            }
            var payload=Data();payload.put(UInt32(index));payload.append(contentsOf:[0,1])
            payload.append(try key.seal(raw))
            let packet=try XCTUnwrap(Wire.parse(Wire.packet(.audio,stream:1,sequence:UInt32(index),payload:payload)))
            XCTAssertTrue(decoder.accept(packet,credentials:key))
            expected.append(contentsOf:Array(repeating:[left,right],count:packetFrames).flatMap { $0 })
        }
        XCTAssertEqual(decoder.queuedFrames,capacity)
        XCTAssertTrue(decoder.read(capacity)==Array(expected.suffix(capacity*2)))
        XCTAssertEqual(decoder.takeUnderruns(),0)
    }
}
