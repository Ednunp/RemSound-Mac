import AVFoundation
import AudioSupport
import Foundation
import RemSoundJam
import RemSoundRuntime

@MainActor
protocol PushToTalkPreviewOutput: AnyObject {
    func play() -> Bool
    func stop()
}
final class PushToTalkPreviewRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var delivered = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func claimDelivery() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, !delivered else { return false }; delivered = true; return true
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
enum PushToTalkPreviewBuffer {
    static let sampleRate = Int(RS_TYPING_SAMPLE_RATE)
    static let channels = 2
    private static let bytesPerSample = 4
    fileprivate static let waveHeaderBytes = 44
    private static let ieeeFloatFormat: UInt16 = 3
    private static let formatChunkBytes: UInt32 = 16
    static let maximumClipFrames = sampleRate * Int(PushToTalkDoubleTapSpeed.fast.maximumIntervalMilliseconds) / 1000
    static let maximumWaveBytes = waveHeaderBytes + (sampleRate * Int(PushToTalkDoubleTapSpeed.slow.maximumIntervalMilliseconds) / 1000 + maximumClipFrames) * channels * bytesPerSample
    static func render(_ clip: [Float], speed: PushToTalkDoubleTapSpeed) -> [Float]? {
        guard !clip.isEmpty, clip.count.isMultiple(of: channels), clip.count <= maximumClipFrames * channels,
              clip.allSatisfy({ $0.isFinite }) else { return nil }
        let offset = sampleRate * Int(speed.maximumIntervalMilliseconds) / 1000 * channels
        var samples = [Float](repeating: 0, count: offset + clip.count)
        samples.replaceSubrange(0..<clip.count, with: clip)
        samples.replaceSubrange(offset..<samples.count, with: clip)
        return samples
    }
    static func wave(_ samples: [Float]) -> Data? {
        guard !samples.isEmpty, samples.count.isMultiple(of: channels),
              samples.count <= (maximumWaveBytes - waveHeaderBytes) / bytesPerSample,
              samples.allSatisfy({ $0.isFinite }) else { return nil }
        let payload = samples.map { $0.bitPattern.littleEndian }
        var data = Data()
        func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        data.append(contentsOf: "RIFF".utf8); u32(UInt32(waveHeaderBytes - 8 + payload.count * bytesPerSample))
        data.append(contentsOf: "WAVEfmt ".utf8); u32(formatChunkBytes)
        u16(ieeeFloatFormat) // WAVE_FORMAT_IEEE_FLOAT preserves the decoded click without quantization or normalization.
        u16(UInt16(channels)); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * channels * bytesPerSample))
        u16(UInt16(channels * bytesPerSample)); u16(UInt16(bytesPerSample * 8))
        data.append(contentsOf: "data".utf8); u32(UInt32(payload.count * bytesPerSample))
        payload.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}

@MainActor
final class PushToTalkPreview {
    typealias Prepare = (PushToTalkDoubleTapSpeed, PushToTalkPreviewRequest, @escaping @MainActor (Data?) -> Void) -> Void
    typealias MakeOutput = (Data, @escaping @MainActor (Bool) -> Void) throws -> PushToTalkPreviewOutput
    private let isAllowed: () -> Bool
    private let prepare: Prepare
    private let makeOutput: MakeOutput
    private var request: PushToTalkPreviewRequest?
    private var current: Playback?
    private var closed = false
    var onFailure: ((String) -> Void)?
    var onStarted: (() -> Void)?
    var hasOutput: Bool { current?.output != nil }
    @MainActor
    private final class Playback {
        var output: PushToTalkPreviewOutput?
        private(set) var retired = false
        func attach(_ value: PushToTalkPreviewOutput) {
            if retired { value.stop() } else { output = value }
        }
        func retire() {
            guard !retired else { return }
            retired = true; let old = output; output = nil; old?.stop()
        }
    }
    init(isAllowed: @escaping () -> Bool, prepare: @escaping Prepare, makeOutput: @escaping MakeOutput) {
        self.isAllowed = isAllowed; self.prepare = prepare; self.makeOutput = makeOutput
    }
    deinit { MainActor.assumeIsolated { request?.cancel(); current?.retire() } }
    static func native(configuration: RuntimeConfiguration, preferences: CuePreferences, directory: URL?) -> PushToTalkPreview {
        let producer = PushToTalkPreviewProducer(directory: directory)
        return PushToTalkPreview(isAllowed: {
            !configuration.silent && !configuration.isHeadless && !configuration.isIsolated && !preferences.muteAllCues
        }, prepare: { producer.prepare($0, request: $1, completion: $2) },
        makeOutput: { try NativePushToTalkPreviewOutput(configuration: configuration, data: $0, completion: $1) })
    }
    func play(_ speed: PushToTalkDoubleTapSpeed) {
        guard !closed else { return }
        stop()
        guard isAllowed() else { return }
        let ticket = PushToTalkPreviewRequest(); request = ticket
        prepare(speed, ticket) { [weak self] data in self?.accept(data, ticket: ticket) }
    }
    func refresh() { if !isAllowed() { stop() } }
    func stop() {
        request?.cancel(); request = nil
        let old = current; current = nil; old?.retire()
    }
    func shutdown() { guard !closed else { return }; closed = true; stop(); onFailure = nil; onStarted = nil }
    private func accepts(_ ticket: PushToTalkPreviewRequest) -> Bool {
        !closed && request === ticket && !ticket.isCancelled && isAllowed()
    }
    private func accept(_ data: Data?, ticket: PushToTalkPreviewRequest) {
        guard accepts(ticket), ticket.claimDelivery() else { return }
        guard let data, data.count > PushToTalkPreviewBuffer.waveHeaderBytes, data.count <= PushToTalkPreviewBuffer.maximumWaveBytes else {
            stop(); onFailure?("Double-tap preview sound is unavailable."); return
        }
        // Publish the lease before constructing the backend: a synchronous completion or
        // policy change must retire even a resource that returns after that callback.
        let lease = Playback(); current = lease
        do {
            let output = try makeOutput(data) { [weak self] success in self?.finished(ticket, success: success) }
            lease.attach(output)
            guard accepts(ticket), current === lease, !lease.retired else { lease.retire(); return }
            if !output.play() { finished(ticket, success: false) }
            else if accepts(ticket), current === lease, !lease.retired { onStarted?() }
        } catch { finished(ticket, success: false) }
    }
    private func finished(_ ticket: PushToTalkPreviewRequest, success: Bool) {
        guard request === ticket, !ticket.isCancelled else { return }
        stop()
        if !success { onFailure?("Double-tap preview could not be played.") }
    }
}

// Decoding and finite-buffer serialization belong to this serial producer, never an audio callback.
private final class PushToTalkPreviewProducer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.remsound.ptt-preview", qos: .utility)
    private let directory: URL?
    private var clip: [Float]?
    init(directory: URL?) { self.directory = directory }
    func prepare(_ speed: PushToTalkDoubleTapSpeed, request: PushToTalkPreviewRequest,
                 completion: @escaping @MainActor (Data?) -> Void) {
        queue.async { [self] in
            guard !request.isCancelled else { return }
            if clip == nil, let directory { clip = TypingAudioCache.decode(directory.appendingPathComponent("key 1.wav")) }
            guard !request.isCancelled else { return }
            let data = clip.flatMap { PushToTalkPreviewBuffer.render($0, speed: speed) }.flatMap { PushToTalkPreviewBuffer.wave($0) }
            guard !request.isCancelled else { return }
            DispatchQueue.main.async { completion(data) }
        }
    }
}

@MainActor
final class NativePushToTalkPreviewOutput: NSObject, PushToTalkPreviewOutput, AVAudioPlayerDelegate {
    private let player: AVAudioPlayer
    private var completion: ((Bool) -> Void)?
    private var retired = false
    init(configuration: RuntimeConfiguration, data: Data, completion: @escaping (Bool) -> Void,
         create: (Data) throws -> AVAudioPlayer = { try AVAudioPlayer(data: $0) }) throws {
        guard !configuration.silent, !configuration.isHeadless, !configuration.isIsolated else {
            throw NSError(domain: "RemSoundPreview", code: 1)
        }
        player = try create(data); self.completion = completion
        super.init(); player.numberOfLoops = 0; player.delegate = self
    }
    deinit { MainActor.assumeIsolated { if !retired { player.delegate = nil; player.stop() } } }
    func play() -> Bool { !retired && player.play() }
    func stop() { guard !retired else { return }; retired = true; completion = nil; player.delegate = nil; player.stop() }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in self?.completion?(flag) }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async { [weak self] in self?.completion?(false) }
    }
}
