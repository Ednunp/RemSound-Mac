import AudioToolbox
import CoreAudio
import Foundation

// Setup observations only. HAL frame components remain separate from AVAudioEngine's
// presentation latency, which may already include them; none changes timing or routing.
struct DeviceConfigurationSnapshot {
    struct Stream {
        let id: AudioStreamID
        let virtualRate: Double?
        let physicalRate: Double?
        let channels: UInt32?
        let latencyFrames: Double?
    }
    let id: AudioDeviceID
    let name: String
    let direction: AudioDeviceDirection
    let nominalRate: Double?
    let actualRate: Double?
    let bufferFrames: Double?
    let deviceLatencyFrames: Double?
    let safetyOffsetFrames: Double?
    let presentationLatencySeconds: Double?
    let streams: [Stream]?

    var logDescription: String {
        func value(_ number: Double?) -> String {
            number.map { String(format: "%.3f", $0) } ?? "unavailable"
        }
        let streamText = streams.map { list in
            list.map {
                "stream \($0.id): virtual rate \(value($0.virtualRate)) Hz, "
                    + "physical rate \(value($0.physicalRate)) Hz, "
                    + "channels \($0.channels.map(String.init) ?? "unavailable"), "
                    + "latency \(value($0.latencyFrames)) frames"
            }.joined(separator: "; ")
        } ?? "streams unavailable"
        let estimates = delayEstimate.map {
            "Hardware component estimate \(value($0.hardwareSeconds * 1000)) ms; "
                + "IO component estimate \(value($0.ioStagingSeconds * 1000)) ms "
                + "(device + worst advertised stream + safety + buffer, nominal rate)."
        } ?? "Hardware/IO combined estimate unavailable: missing or inconsistent frame-unit reports."
        return "Core Audio setup \(direction.label) \(name) (ID \(id)): "
            + "nominal rate \(value(nominalRate)) Hz, actual rate \(value(actualRate)) Hz, "
            + "buffer \(value(bufferFrames)) frames, device latency \(value(deviceLatencyFrames)) frames, "
            + "safety offset \(value(safetyOffsetFrames)) frames, "
            + "AV presentation delay \(value(presentationLatencySeconds.map { $0 * 1000 })) ms; "
            + streamText + "; \(estimates) HAL components not added to AV presentation delay. "
            + "Component estimates, not measured acoustic latency."
    }
}

struct DeviceConfigurationReader {
    let readScalar: (AudioObjectID, AudioObjectPropertySelector, AudioObjectPropertyScope) -> Double?
    let readStreams: (AudioDeviceID, AudioObjectPropertyScope) -> [DeviceConfigurationSnapshot.Stream]?

    func snapshot(id: AudioDeviceID, name: String, direction: AudioDeviceDirection,
                  presentationLatencySeconds: Double?) -> DeviceConfigurationSnapshot {
        func number(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
                    positive: Bool = false) -> Double? {
            guard let value = readScalar(id, selector, scope), value.isFinite,
                  positive ? value > 0 : value >= 0 else { return nil }
            return value
        }
        let presentation = presentationLatencySeconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        return .init(id: id, name: name, direction: direction,
            nominalRate: number(kAudioDevicePropertyNominalSampleRate, scope: kAudioObjectPropertyScopeGlobal, positive: true),
            actualRate: number(kAudioDevicePropertyActualSampleRate, scope: kAudioObjectPropertyScopeGlobal, positive: true),
            bufferFrames: number(kAudioDevicePropertyBufferFrameSize, scope: kAudioObjectPropertyScopeGlobal, positive: true),
            deviceLatencyFrames: number(kAudioDevicePropertyLatency, scope: direction.scope),
            safetyOffsetFrames: number(kAudioDevicePropertySafetyOffset, scope: direction.scope),
            presentationLatencySeconds: presentation, streams: readStreams(id, direction.scope))
    }

    static let hardware = DeviceConfigurationReader(readScalar: { id, selector, scope in
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                mElement: kAudioObjectPropertyElementMain)
        if selector == kAudioDevicePropertyNominalSampleRate || selector == kAudioDevicePropertyActualSampleRate {
            var value: Float64 = 0
            var size = UInt32(MemoryLayout<Float64>.size)
            guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
                  size == MemoryLayout<Float64>.size else { return nil }
            return value
        }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              size == MemoryLayout<UInt32>.size else { return nil }
        return Double(value)
    }, readStreams: { id, scope in
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope,
                                                mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              Int(size).isMultiple(of: MemoryLayout<AudioStreamID>.size) else { return nil }
        guard size > 0 else { return [] }
        let expectedSize = size
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        let status = streams.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr, size == expectedSize else { return nil }
        func format(_ stream: AudioStreamID, selector: AudioObjectPropertySelector) -> AudioStreamBasicDescription? {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                    mElement: kAudioObjectPropertyElementMain)
            var value = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &value) == noErr,
                  size == MemoryLayout<AudioStreamBasicDescription>.size else { return nil }
            return value
        }
        func rate(_ value: Double?) -> Double? {
            value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        }
        return streams.map { stream in
            let virtual = format(stream, selector: kAudioStreamPropertyVirtualFormat)
            let physical = format(stream, selector: kAudioStreamPropertyPhysicalFormat)
            var address = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyLatency,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var latency: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &latency)
            return .init(id: stream, virtualRate: rate(virtual?.mSampleRate),
                physicalRate: rate(physical?.mSampleRate), channels: virtual?.mChannelsPerFrame,
                latencyFrames: status == noErr && size == MemoryLayout<UInt32>.size ? Double(latency) : nil)
        }
    })
}
