import Foundation
enum WebAudioPackets {
    private static let version:UInt8=1
    private static let pcmBytesPerSample=2
    private static let pcmScale:Float=32767
    static let frameSamples=240
    static let channels=2
    static let headerSize=6
    static let maximumOpusPayload=4000
    static let pcmBytes=frameSamples*channels*pcmBytesPerSample
    enum Codec {case opus,pcm16}
    struct Packet {let stream:UInt8,sequence:UInt32,payload:Data}
    private static func validPayload(_ count:Int,codec:Codec)->Bool {
        switch codec {case .opus:return (1...maximumOpusPayload).contains(count);case .pcm16:return count==pcmBytes}
    }
    static func packet(stream:UInt8,sequence:UInt32,payload:Data,codec:Codec)->Data? {
        guard validPayload(payload.count,codec:codec) else {return nil}
        var bytes=Data([version,stream]);bytes.put(sequence);bytes.append(payload)
        return bytes
    }
    static func parse(_ bytes:Data,codec:Codec)->Packet? {
        guard bytes.count>headerSize,bytes.count<=headerSize+maximumOpusPayload,
            validPayload(bytes.count-headerSize,codec:codec) else {return nil}
        // Data slices may retain nonzero indices. Copy only the already bounded six-byte header.
        let header=Array(bytes.prefix(headerSize));guard header[0]==version else {return nil}
        let sequence=UInt32(header[2]) | UInt32(header[3])<<8 | UInt32(header[4])<<16 | UInt32(header[5])<<24
        return .init(stream:header[1],sequence:sequence,payload:Data(bytes.dropFirst(headerSize)))
    }
    static func pcm(_ samples:[Float])->Data? {
        guard samples.count==frameSamples*channels,samples.allSatisfy(\.isFinite) else {return nil}
        var bytes=Data();bytes.reserveCapacity(pcmBytes)
        for sample in samples {
            // Match Windows' float multiplication then Math.Round ties-to-even, including -32767.
            let scaled=min(1,max(-1,sample))*pcmScale
            bytes.put(Int16(scaled.rounded(.toNearestOrEven)))
        }
        return bytes
    }
}
