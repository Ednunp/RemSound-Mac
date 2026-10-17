import AVFoundation
import AudioSupport
import AudioToolbox
import Foundation
import RemSoundJam

public enum RecordingSource: String, CaseIterable, Codable {
    case both, received, sent

    public var label: String {
        switch self {
        case .both: "Record sent and received audio"
        case .received: "Record received audio"
        case .sent: "Record sent audio"
        }
    }
}

public enum RecordingChannels: String, CaseIterable, Codable {
    case stereo, mono

    public var label: String { self == .stereo ? "Stereo" : "Mono, mix left and right" }
    var count: AVAudioChannelCount { self == .stereo ? 2 : 1 }
}

public enum FLACCompression {
    public static let defaultLevel = Int(RS_FLAC_DEFAULT_COMPRESSION)
    public static let maximumLevel = Int(RS_FLAC_MAX_COMPRESSION)
    public static func clamped(_ level: Int) -> Int { min(maximumLevel, max(0, level)) }
}

public enum RecordingFormat: String, CaseIterable, Codable {
    case wav16, wav24, wavFloat, flac16, flac24
    case mp3128, mp3192, mp3256, mp3320
    // Ogg Opus, as the Windows recorder makes it (music mode, unconstrained VBR, 20 ms frames); 192 kbps is its default.
    case opus96, opus128, opus192, opus256

    public var label: String {
        switch self {
        case .wav16: "WAV, 16-bit"
        case .wav24: "WAV, 24-bit"
        case .wavFloat: "WAV, 32-bit float"
        case .flac16: "FLAC, 16-bit"
        case .flac24: "FLAC, 24-bit"
        case .mp3128: "MP3, 128 kbps"
        case .mp3192: "MP3, 192 kbps"
        case .mp3256: "MP3, 256 kbps"
        case .mp3320: "MP3, 320 kbps"
        case .opus96: "Ogg Opus, 96 kbps"
        case .opus128: "Ogg Opus, 128 kbps"
        case .opus192: "Ogg Opus, 192 kbps"
        case .opus256: "Ogg Opus, 256 kbps"
        }
    }
    public var fileExtension: String {
        switch self {
        case .wav16, .wav24, .wavFloat: "wav"
        case .flac16, .flac24: "flac"
        case .mp3128, .mp3192, .mp3256, .mp3320: "mp3"
        case .opus96, .opus128, .opus192, .opus256: "opus"
        }
    }
    /// Bits a second for the Ogg Opus choices; nil for the rest.
    public var opusBitrate: Int? {
        switch self {
        case .opus96: 96_000
        case .opus128: 128_000
        case .opus192: 192_000
        case .opus256: 256_000
        default: nil
        }
    }
    var mp3Bitrate: Int? {
        switch self {
        case .mp3128: 128
        case .mp3192: 192
        case .mp3256: 256
        case .mp3320: 320
        default: nil
        }
    }
    func settings(channels: RecordingChannels = .stereo) -> [String: Any] {
        var values: [String: Any] = [
            AVFormatIDKey: fileExtension == "wav" ? kAudioFormatLinearPCM : kAudioFormatFLAC,
            AVSampleRateKey: 48000, AVNumberOfChannelsKey: channels.count,
        ]
        switch self {
        case .wav16, .flac16: values[AVLinearPCMBitDepthKey] = 16
        case .wav24, .flac24: values[AVLinearPCMBitDepthKey] = 24
        case .wavFloat:
            values[AVLinearPCMBitDepthKey] = 32
            values[AVLinearPCMIsFloatKey] = true
        case .opus96, .opus128, .opus192, .opus256, .mp3128, .mp3192, .mp3256, .mp3320: break // Encoded by their file writers.
        }
        if fileExtension == "wav" {
            values[AVLinearPCMIsBigEndianKey] = false
            values[AVLinearPCMIsNonInterleaved] = false
            if self != .wavFloat { values[AVLinearPCMIsFloatKey] = false }
        }
        return values
    }
}

/// An Ogg Opus recording: libopus (AudioSupport) encoding 20 ms frames, RemSoundJam's OggOpusRecorder laying them out,
/// the pages written as they fill (about a second each). Used on the recording writer's queue only.
final class OggOpusFile {
    private var encoder: UnsafeMutableRawPointer?
    private var recorder: OggOpusRecorder
    private let handle: FileHandle

    init(url: URL, channels: Int, bitrate: Int) throws {
        var lookahead: Int32 = 0
        guard let encoder = rs_opus_file_encoder(Int32(channels), Int32(bitrate), &lookahead) else {
            throw ProtocolError.invalid("The Opus encoder could not be started.")
        }
        self.encoder = encoder
        let (recorder, header) = OggOpusRecorder.start(channels: channels, preSkip: Int(lookahead),
            serial: UInt32.random(in: 1...UInt32.max)) { frame in
            var packet = [UInt8](repeating: 0, count: 4000)
            let n = frame.withUnsafeBufferPointer { samples in
                packet.withUnsafeMutableBufferPointer {
                    rs_opus_encode(encoder, samples.baseAddress, Int32(frame.count / channels), $0.baseAddress, 4000)
                }
            }
            return n > 0 ? Array(packet.prefix(Int(n))) : nil
        }
        self.recorder = recorder
        guard FileManager.default.createFile(atPath: url.path, contents: Data(header)) else {
            rs_opus_encoder_destroy(encoder)
            throw ProtocolError.invalid("Could not create \(url.lastPathComponent).")
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }
    /// Interleaved stereo; mixed to mono by the recorder if the file is mono.
    func write(_ stereo: [Float]) throws {
        let bytes = recorder.append(stereo: stereo)
        if !bytes.isEmpty { try handle.write(contentsOf: Data(bytes)) }
    }
    /// The last pages, then the file closed. Frames the encoder refused.
    func close() throws -> Int {
        defer {
            try? handle.close()
            if let encoder { rs_opus_encoder_destroy(encoder) }
            encoder = nil
        }
        try handle.write(contentsOf: Data(recorder.finish()))
        return recorder.failedFrames
    }
}

/// LAME encoding and file access stay on RecordingFile's serial writer queue.
final class MP3File {
    private static let syncInterval: TimeInterval = 5
    private var encoder: UnsafeMutableRawPointer?
    private let handle: FileHandle
    private var packet = [UInt8](repeating: 0, count: Int(RS_MP3_BUFFER_BYTES))
    private var lastSync = ProcessInfo.processInfo.systemUptime

    init(url: URL, channels: Int, bitrate: Int) throws {
        guard let encoder = rs_mp3_file_encoder(Int32(channels), Int32(bitrate)) else {
            throw ProtocolError.invalid("The MP3 encoder could not be started.")
        }
        do {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw ProtocolError.invalid("Could not create \(url.lastPathComponent).")
            }
            handle = try FileHandle(forWritingTo: url)
        } catch {
            rs_mp3_file_destroy(encoder)
            throw error
        }
        self.encoder = encoder
    }

    deinit {
        if let encoder { rs_mp3_file_destroy(encoder) }
        try? handle.close()
    }

    func write(_ stereo: [Float]) throws {
        guard let encoder, stereo.count.isMultiple(of: 2) else {
            throw ProtocolError.invalid("The MP3 recording is closed or its samples are incomplete.")
        }
        try stereo.withUnsafeBufferPointer { samples in
            var frame = 0
            while frame < stereo.count / 2 {
                let count = min(Int(RS_MP3_MAX_FRAMES), stereo.count / 2 - frame)
                let bytes = packet.withUnsafeMutableBufferPointer {
                    rs_mp3_file_encode(encoder, samples.baseAddress!.advanced(by: frame * 2),
                        Int32(count), $0.baseAddress, Int32($0.count))
                }
                try writePacket(bytes)
                frame += count
            }
        }
        // Sync completed frames without finalizing the encoder or resetting its delay.
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastSync >= Self.syncInterval {
            try handle.synchronize()
            lastSync = now
        }
    }

    func close() throws {
        guard let encoder else { return }
        defer {
            rs_mp3_file_destroy(encoder)
            self.encoder = nil
            try? handle.close()
        }
        let flushed = packet.withUnsafeMutableBufferPointer {
            rs_mp3_file_flush(encoder, $0.baseAddress, Int32($0.count))
        }
        try writePacket(flushed)
        let tagged = packet.withUnsafeMutableBufferPointer {
            rs_mp3_file_tag(encoder, $0.baseAddress, Int32($0.count))
        }
        guard tagged > 0 else { throw ProtocolError.invalid("The MP3 recording tag could not be finalized.") }
        try handle.seek(toOffset: 0)
        try writePacket(tagged)
        try handle.synchronize()
    }

    private func writePacket(_ count: Int32) throws {
        guard count >= 0, count <= packet.count else {
            throw ProtocolError.invalid("The MP3 encoder could not write a frame.")
        }
        if count > 0 { try handle.write(contentsOf: Data(packet.prefix(Int(count)))) }
    }
}

/// Lossless encoding and descriptor access stay on RecordingFile's serial writer queue.
final class FLACFile {
    private static let syncInterval: TimeInterval = 5
    private var encoder: UnsafeMutableRawPointer?
    private var lastSync = ProcessInfo.processInfo.systemUptime

    init(url: URL, channels: Int, bits: Int, compression: Int) throws {
        guard (1...2).contains(channels), [16, 24].contains(bits),
            (0...FLACCompression.maximumLevel).contains(compression),
            let encoder = rs_flac_file_encoder(url.path, Int32(channels), Int32(bits), Int32(compression)) else {
            throw ProtocolError.invalid("The FLAC recording could not be created. Check the folder and compression level.")
        }
        self.encoder = encoder
    }

    deinit { if let encoder { rs_flac_file_destroy(encoder) } }

    func write(_ stereo: [Float]) throws {
        guard let encoder, stereo.count.isMultiple(of: 2) else {
            throw ProtocolError.invalid("The FLAC recording is closed or its samples are incomplete.")
        }
        try stereo.withUnsafeBufferPointer { samples in
            var frame = 0
            while frame < stereo.count / 2 {
                let count = min(Int(RS_FLAC_MAX_FRAMES), stereo.count / 2 - frame)
                guard rs_flac_file_encode(encoder, samples.baseAddress!.advanced(by: frame * 2), Int32(count)) != 0 else {
                    throw ProtocolError.invalid("The FLAC encoder could not write a frame.")
                }
                frame += count
            }
        }
        // Sync completed frames without ending the active encoder or dropping its partial frame.
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastSync >= Self.syncInterval {
            try synchronize()
            lastSync = now
        }
    }

    func synchronize() throws {
        guard let encoder, rs_flac_file_sync(encoder) != 0 else {
            throw ProtocolError.invalid("The FLAC recording could not be synchronized to disk.")
        }
    }

    func close() throws {
        guard let encoder else { return }
        defer {
            rs_flac_file_destroy(encoder)
            self.encoder = nil
        }
        guard rs_flac_file_close(encoder) != 0 else {
            throw ProtocolError.invalid("The FLAC recording could not be finalized.")
        }
    }
}

final class RecordingFile {
    private static let maxPendingBlocks = 1000 // Five seconds at 48 kHz, 240 frames per block.
    private let queue = DispatchQueue(label: "RemSound recording writer", qos: .utility)
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var ogg: OggOpusFile?
    private var mp3: MP3File?
    private var flac: FLACFile?
    private let format: AVAudioFormat
    private let channels: RecordingChannels
    private var pending = 0
    private var droppedBlocks = 0
    private var firstWriteError: String?
    let url: URL

    init(url: URL, format recordingFormat: RecordingFormat = .wav24,
        channels: RecordingChannels = .stereo, flacCompression: Int = FLACCompression.defaultLevel) throws {
        self.url = url
        self.channels = channels
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
            channels: channels.count, interleaved: false)!
        if let bitrate = recordingFormat.mp3Bitrate {
            mp3 = try MP3File(url: url, channels: Int(channels.count), bitrate: bitrate)
        } else if let bitrate = recordingFormat.opusBitrate {
            ogg = try OggOpusFile(url: url, channels: Int(channels.count), bitrate: bitrate)
        } else if recordingFormat == .flac16 || recordingFormat == .flac24 {
            flac = try FLACFile(url: url, channels: Int(channels.count),
                bits: recordingFormat == .flac16 ? 16 : 24, compression: flacCompression)
        } else {
            file = try AVAudioFile(forWriting: url, settings: recordingFormat.settings(channels: channels),
                commonFormat: .pcmFormatFloat32, interleaved: false)
        }
    }
    func append(_ samples: [Float]) {
        guard !samples.isEmpty, samples.count.isMultiple(of: 2) else { return }
        lock.lock()
        if firstWriteError != nil {
            lock.unlock()
            return
        }
        if pending >= Self.maxPendingBlocks {
            droppedBlocks += 1
            lock.unlock()
            return
        }
        pending += 1
        lock.unlock()
        queue.async { [self] in
            let frames = samples.count / 2
            if let flac {
                do { try flac.write(samples) }
                catch {
                    lock.lock()
                    droppedBlocks += 1
                    if firstWriteError == nil { firstWriteError = error.localizedDescription }
                    lock.unlock()
                }
            } else if let mp3 {
                do { try mp3.write(samples) }
                catch {
                    lock.lock()
                    droppedBlocks += 1
                    if firstWriteError == nil { firstWriteError = error.localizedDescription }
                    lock.unlock()
                }
            } else if let ogg {
                do { try ogg.write(samples.map { $0.isFinite ? $0 : 0 }) }
                catch {
                    lock.lock()
                    droppedBlocks += 1
                    if firstWriteError == nil { firstWriteError = error.localizedDescription }
                    lock.unlock()
                }
            } else if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) {
                buffer.frameLength = AVAudioFrameCount(frames)
                for i in 0..<frames {
                    let left = samples[2 * i].isFinite ? samples[2 * i] : 0
                    let right = samples[2 * i + 1].isFinite ? samples[2 * i + 1] : 0
                    buffer.floatChannelData![0][i] = channels == .mono ? (left + right) * 0.5 : left
                    if channels == .stereo { buffer.floatChannelData![1][i] = right }
                }
                do { try file?.write(from: buffer) }
                catch {
                    lock.lock()
                    droppedBlocks += 1
                    if firstWriteError == nil { firstWriteError = error.localizedDescription }
                    lock.unlock()
                }
            }
            lock.lock()
            pending -= 1
            lock.unlock()
        }
    }
    func finish(_ completed: @escaping (URL, Int, String?) -> Void) {
        queue.async { [self] in
            file = nil
            if let flac {
                do { try flac.close() }
                catch {
                    lock.lock()
                    if firstWriteError == nil { firstWriteError = error.localizedDescription }
                    lock.unlock()
                }
                self.flac = nil
            }
            if let mp3 {
                do { try mp3.close() }
                catch {
                    lock.lock()
                    if firstWriteError == nil { firstWriteError = error.localizedDescription }
                    lock.unlock()
                }
                self.mp3 = nil
            }
            if let ogg {
                do {
                    // A 20 ms frame the encoder refused is a gap in the file: counted with the dropped blocks.
                    let refused = try ogg.close() / 240
                    lock.lock()
                    droppedBlocks += refused
                    lock.unlock()
                } catch {
                    lock.lock()
                    if firstWriteError == nil { firstWriteError = error.localizedDescription }
                    lock.unlock()
                }
                self.ogg = nil
            }
            lock.lock()
            let drops = droppedBlocks
            let error = firstWriteError
            lock.unlock()
            DispatchQueue.main.async { completed(self.url, drops, error) }
        }
    }
}
