import AudioSupport
import Foundation

public enum SendCodec: String, CaseIterable, Codable {
    case pcm, opusBroadcast, opusLive

    public var label: String {
        switch self {
        case .pcm: "PCM, lossless, lowest coding delay"
        case .opusBroadcast: "Opus broadcast, lower bandwidth"
        case .opusLive: "Opus live, lowest coding delay"
        }
    }
    var frames: Int {
        switch self {
        case .pcm: Wire.pcmFrames
        case .opusBroadcast: SendPacketSize.broadcastFrames
        case .opusLive: SendPacketSize.minimumFrames
        }
    }
    var bitrate: Int {
        switch self {
        case .pcm: 0
        case .opusBroadcast: 192_000
        case .opusLive: 320_000
        }
    }
    func format(_ fingerprint: Data, packetSize: SendPacketSize = .standard) -> StreamFormat {
        let frames = packetSize.frames(for: self)
        return self == .pcm ? .pcm(fingerprint, frames: frames) : .opus(fingerprint, frames: frames)
    }
}

/// Windows packet-size choices affect PCM and broadcast Opus only; live/custom mode is already minimal.
public enum SendPacketSize: String, CaseIterable, Codable {
    case standard, small
    static let minimumFrames = 120
    static let broadcastFrames = 960

    public var label: String {
        switch self {
        case .standard: "Standard"
        case .small: "Small, stable local network"
        }
    }
    func frames(for codec: SendCodec) -> Int {
        switch (codec, self) {
        case (.pcm, .small): Self.minimumFrames
        case (.opusBroadcast, .small): Self.broadcastFrames / 2
        default: codec.frames
        }
    }
}

final class OpusSender {
    private let state: UnsafeMutableRawPointer
    init?(bitrate: Int) {
        guard let encoder = rs_opus_encoder(Int32(bitrate)) else { return nil }
        state = encoder
    }
    deinit { rs_opus_encoder_destroy(state) }
    func encode(_ samples: [Float]) -> Data? {
        guard samples.count.isMultiple(of: 2), samples.count / 2 <= 2880 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 1275)
        let count = samples.withUnsafeBufferPointer { source in
            bytes.withUnsafeMutableBufferPointer { output in
                rs_opus_encode(state, source.baseAddress, Int32(samples.count / 2),
                    output.baseAddress, Int32(output.count))
            }
        }
        guard count > 0 else { return nil }
        return Data(bytes.prefix(Int(count)))
    }
}

/// Jamulus-style Opus frames (64 samples, 1.33 ms) - the Windows latency lab's, for playing together at speed.
final class OpusCustomSender {
    private let state: UnsafeMutableRawPointer
    let frames: Int
    init?(frames: Int = 64) {
        guard let encoder = rs_opus_custom_encoder(Int32(frames), Int32(frames <= 64 ? 320_000 : 256_000)) else { return nil }
        state = encoder
        self.frames = frames
    }
    deinit { rs_opus_custom_encoder_destroy(state) }
    func encode(_ samples: [Float]) -> Data? {
        guard samples.count == frames * 2 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 1275)
        let count = samples.withUnsafeBufferPointer { source in
            bytes.withUnsafeMutableBufferPointer { output in
                rs_opus_custom_encode(state, source.baseAddress, output.baseAddress, Int32(output.count))
            }
        }
        guard count > 0 else { return nil }
        return Data(bytes.prefix(Int(count)))
    }
}
