import AudioSupport
import XCTest

final class CustomOpusTests: XCTestCase {
    func testRealCustomCodecPreservesStereoToneAtBothFrameSizes() throws {
        for frames in [64, 128] {
            let encoder = try XCTUnwrap(rs_opus_custom_encoder(Int32(frames), 320_000))
            let decoder = try XCTUnwrap(rs_opus_custom_decoder(Int32(frames)))
            defer {
                rs_opus_custom_encoder_destroy(encoder)
                rs_opus_custom_decoder_destroy(decoder)
            }
            var output: [Float] = []
            for block in 0..<(48_000 / frames) {
                var input = [Float](repeating: 0, count: frames * 2)
                for i in 0..<frames {
                    let sample = Float(sin(Double(block * frames + i) * 2 * .pi * 440 / 48_000)) * 0.25
                    input[i * 2] = sample
                    input[i * 2 + 1] = -sample
                }
                var packet = [UInt8](repeating: 0, count: 1275)
                let count = input.withUnsafeBufferPointer { samples in
                    packet.withUnsafeMutableBufferPointer {
                        rs_opus_custom_encode(encoder, samples.baseAddress, $0.baseAddress, Int32($0.count))
                    }
                }
                XCTAssertGreaterThan(count, 0)
                var decoded = [Float](repeating: 0, count: frames * 2)
                let read = packet.withUnsafeBufferPointer { bytes in
                    decoded.withUnsafeMutableBufferPointer {
                        rs_opus_custom_decode(decoder, bytes.baseAddress, count, $0.baseAddress)
                    }
                }
                XCTAssertEqual(read, Int32(frames))
                XCTAssertTrue(decoded.allSatisfy(\.isFinite))
                output.append(contentsOf: decoded)
            }
            let left = stride(from: 4800 * 2, to: output.count, by: 2).map { output[$0] }
            let crossings = zip(left, left.dropFirst()).filter { $0.0 <= 0 && $0.1 > 0 }.count
            XCTAssertEqual(Double(crossings) * 48_000 / Double(left.count), 440, accuracy: 3)
            XCTAssertGreaterThan(left.reduce(0) { $0 + $1 * $1 } / Float(left.count), 0.01)
            let stereoError = stride(from: 4800 * 2, to: output.count, by: 2)
                .map { abs(output[$0] + output[$0 + 1]) }.max() ?? 1
            XCTAssertLessThan(stereoError, 0.02)
            var concealed = [Float](repeating: 0, count: frames * 2)
            XCTAssertEqual(concealed.withUnsafeMutableBufferPointer {
                rs_opus_custom_decode(decoder, nil, 0, $0.baseAddress)
            }, Int32(frames))
            XCTAssertTrue(concealed.allSatisfy(\.isFinite))
        }
    }
}
