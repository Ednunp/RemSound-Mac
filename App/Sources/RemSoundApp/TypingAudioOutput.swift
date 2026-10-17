import AVFoundation
import AudioSupport
import Foundation

extension TypingAudioCache {
    static func bundled(directory: URL?) -> TypingAudioCache {
        guard let directory else { return TypingAudioCache(assets: [:]) }
        var assets: [Int: [Float]] = [:]
        for index in 0..<Int(RS_TYPING_ASSETS) {
            let name = index == Int(RS_TYPING_PASSWORD_ASSET) ? "passkey.wav" : "key \(index + 1).wav"
            if let samples = decode(directory.appendingPathComponent(name)) { assets[index] = samples }
        }
        return TypingAudioCache(assets: assets)
    }
    // This whole-file conversion runs once on the producer queue, never on an audio callback.
    static func decode(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false),
            file.length > 0, file.processingFormat.sampleRate > 0,
            file.processingFormat.channelCount > 0, file.processingFormat.channelCount <= 2 else { return nil }
        let expected = ceil(Double(file.length) * Double(RS_TYPING_SAMPLE_RATE) / file.processingFormat.sampleRate)
        guard expected > 0, expected <= Double(RS_TYPING_MAX_ASSET_FRAMES),
            file.length <= Int64(UInt32.max),
            let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: UInt32(file.length)),
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                sampleRate: Double(RS_TYPING_SAMPLE_RATE), channels: 2, interleaved: false),
            let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(expected) + 64),
            let converter = AVAudioConverter(from: file.processingFormat, to: format) else { return nil }
        do { try file.read(into: input) } catch { return nil }
        var supplied = false, error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            guard !supplied else { state.pointee = .endOfStream; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        guard status != .error, error == nil, output.frameLength > 0,
            output.frameLength <= UInt32(RS_TYPING_MAX_ASSET_FRAMES),
            let channels = output.floatChannelData else { return nil }
        var stereo = [Float](repeating: 0, count: Int(output.frameLength) * 2)
        for frame in 0..<Int(output.frameLength) {
            let left = channels[0][frame], right = channels[1][frame]
            guard left.isFinite, right.isFinite else { return nil }
            stereo[frame * 2] = left; stereo[frame * 2 + 1] = right
        }
        return stereo
    }
}

private final class TypingMixerContext {
    let mixer: OpaquePointer
    init(cache: TypingAudioCache) throws {
        guard !cache.keys.isEmpty else { throw TypingAudioOutput.Failure.invalidAsset }
        guard let mixer = RSTypingMixerCreate() else { throw TypingAudioOutput.Failure.unavailable }
        var retained = false
        defer { if !retained { RSTypingMixerDestroy(mixer) } }
        for (index, samples) in cache.assets {
            guard (0..<Int(RS_TYPING_ASSETS)).contains(index), !samples.isEmpty,
                samples.count.isMultiple(of: 2), samples.count <= Int(RS_TYPING_MAX_ASSET_FRAMES) * 2 else {
                throw TypingAudioOutput.Failure.invalidAsset
            }
            let loaded = samples.withUnsafeBufferPointer {
                RSTypingMixerSetAsset(mixer, UInt32(index), $0.baseAddress, UInt32(samples.count / 2))
            }
            guard loaded == 1 else { throw TypingAudioOutput.Failure.invalidAsset }
        }
        self.mixer = mixer; retained = true
    }
    deinit { RSTypingMixerDestroy(mixer) }
}

// One independent default-output engine. The callback captures the native context,
// so its immutable samples outlive any in-flight render when the engine is retired.
final class TypingAudioOutput: TypingSoundOutput {
    enum Failure: Error { case unavailable, invalidAsset }
    private let context: TypingMixerContext
    private let engine: AVAudioEngine
    private let source: AVAudioSourceNode
    private let routeLock = NSLock()
    private var routeChanged = false
    private var retired = false
    private var routeToken: NSObjectProtocol?
    var isRunning: Bool {
        routeLock.lock(); let usable = !routeChanged; routeLock.unlock()
        return !retired && usable && engine.isRunning
    }
    init(cache: TypingAudioCache) throws {
        let context = try TypingMixerContext(cache: cache)
        self.context = context
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: Double(RS_TYPING_SAMPLE_RATE), channels: 2, interleaved: false) else { throw Failure.unavailable }
        source = AVAudioSourceNode(format: format) { [context] silence, _, frames, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard buffers.count == 2, buffers[0].mNumberChannels == 1, buffers[1].mNumberChannels == 1,
                buffers[0].mDataByteSize >= frames * UInt32(MemoryLayout<Float>.size),
                buffers[1].mDataByteSize >= frames * UInt32(MemoryLayout<Float>.size),
                let left = buffers[0].mData, let right = buffers[1].mData else {
                for buffer in buffers { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
                silence.pointee = true; return noErr
            }
            RSTypingMixerRender(context.mixer, left.assumingMemoryBound(to: Float.self),
                right.assumingMemoryBound(to: Float.self), frames)
            silence.pointee = false
            return noErr
        }
        engine = AVAudioEngine()
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
    }
    deinit { stop() }
    func start() throws {
        guard !retired else { throw Failure.unavailable }
        if routeToken != nil { return }
        engine.prepare()
        try engine.start()
        routeToken = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: nil) { [weak self] _ in
                guard let self else { return }
                routeLock.lock(); routeChanged = true
                RSTypingMixerSetEnabled(context.mixer, 0); routeLock.unlock()
            }
    }
    func setEnabled(_ enabled: Bool) {
        routeLock.lock()
        RSTypingMixerSetEnabled(context.mixer, enabled && !routeChanged ? 1 : 0)
        routeLock.unlock()
    }
    func enqueue(key: Int, password: Bool) {
        _ = RSTypingMixerEnqueue(context.mixer, UInt32(key), password ? 1 : 0)
    }
    func stop() {
        guard !retired else { return }
        retired = true
        RSTypingMixerSetEnabled(context.mixer, 0)
        if let routeToken { NotificationCenter.default.removeObserver(routeToken); self.routeToken = nil }
        engine.stop()
        engine.disconnectNodeOutput(source)
        engine.detach(source)
    }
}
