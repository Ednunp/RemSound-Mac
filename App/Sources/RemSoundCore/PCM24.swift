import Foundation

/// The ordinary Session wire codec. Raw sample conversion stays inside Core.
enum PCM24 {
    static let sampleBytes=3
    private static let scale: Float=8_388_608
    private static let largestPositive: Float=1-1/scale
    // The existing 255-fragment encrypted PCM envelope, checked before allocating output.
    static let maximumSamples=(Int(UInt8.max)*Wire.maxAudioPayload-28)/sampleBytes
    static func encode(_ samples: [Float]) -> Data? {
        guard samples.count <= maximumSamples else { return nil }
        var bytes=Data(capacity:samples.count*sampleBytes)
        for sample in samples {
            let safe=sample.isFinite ? max(-1,min(largestPositive,sample)) : 0
            let raw=UInt32(bitPattern:Int32(safe*scale))
            bytes.append(UInt8(truncatingIfNeeded:raw))
            bytes.append(UInt8(truncatingIfNeeded:raw >> 8))
            bytes.append(UInt8(truncatingIfNeeded:raw >> 16))
        }
        return bytes
    }
    static func decode(_ payload: Data) -> [Float]? {
        guard payload.count <= maximumSamples*sampleBytes, payload.count % sampleBytes == 0 else { return nil }
        let bytes=Data(payload)
        return stride(from:0,to:bytes.count,by:sampleBytes).map { decodeSample(bytes,at:$0) }
    }
    // Session's StreamDecoder validates the complete authenticated PCM frame before reading samples.
    static func decodeSample(_ bytes: Data, at offset: Int) -> Float {
        let raw=UInt32(bytes[offset]) | UInt32(bytes[offset+1]) << 8 | UInt32(bytes[offset+2]) << 16
        return Float(Int32(bitPattern:raw << 8) >> 8)/scale
    }
}
