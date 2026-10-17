import Foundation
import XCTest
@testable import RemSoundCore

final class PCM24Tests: XCTestCase {
    func testSignedLittleEndianGoldenBytesClampAndNonfiniteSilence() throws {
        let source:[Float]=[0,1,-1,0.5,-0.5,2,-2,.nan,.infinity,-.infinity]
        let golden=Data([0,0,0, 255,255,127, 0,0,128, 0,0,64, 0,0,192,
            255,255,127, 0,0,128, 0,0,0, 0,0,0, 0,0,0])
        XCTAssertEqual(try XCTUnwrap(PCM24.encode(source)),golden)
        let decoded=try XCTUnwrap(PCM24.decode(golden))
        XCTAssertEqual(decoded,[0,1-1/8_388_608,-1,0.5,-0.5,1-1/8_388_608,-1,0,0,0])
    }
    func testEnvelopeBoundMalformedSamplesAndEmptyPrimitive() throws {
        XCTAssertEqual(PCM24.encode([]),Data());XCTAssertEqual(PCM24.decode(Data()),[])
        XCTAssertNil(PCM24.decode(Data([0])));XCTAssertNil(PCM24.decode(Data([0,0])))
        XCTAssertNil(PCM24.encode(Array(repeating:0,count:PCM24.maximumSamples+1)))
        XCTAssertNil(PCM24.decode(Data(repeating:0,count:(PCM24.maximumSamples+1)*3)))
        XCTAssertEqual(PCM24.encode(Array(repeating:0,count:PCM24.maximumSamples))?.count,PCM24.maximumSamples*3)
    }
    func testSlicedDataUsesSampleOffsetsAndRetainsTinySignedSamples() throws {
        let storage=Data([99,1,0,0,255,255,255,99])
        let decoded=try XCTUnwrap(PCM24.decode(storage[1..<7]))
        XCTAssertEqual(decoded,[1/8_388_608,-1/8_388_608])
    }
}
