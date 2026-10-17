import AudioToolbox
import CoreAudio
import Foundation

public enum AudioDeviceDirection: CaseIterable {
    case input, output

    var scope: AudioObjectPropertyScope {
        self == .input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
    }
    var label: String { self == .input ? "input" : "output" }
}

public struct AudioDeviceChoice: Equatable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
}

public struct SystemCaptureChannelRoute: Equatable {
    public let pair: Int
    public let stream: UInt
    public let pairInStream: Int
}

public enum AudioDeviceCatalogError: LocalizedError {
    case unavailable(AudioDeviceDirection)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let direction):
            "The selected audio \(direction.label) is unavailable. Choose another device."
        }
    }
}

public enum AudioDeviceCatalog {
    static let builtInMicrophoneUID = "BuiltInMicrophoneDevice"

    static func isBuiltInMicrophone(_ selectedUID: String) -> Bool {
        if !selectedUID.isEmpty { return selectedUID == builtInMicrophoneUID }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &id) == noErr else { return false }
        return choices(for: .input).contains { $0.id == id && $0.uid == builtInMicrophoneUID }
    }

    public static func choices(for direction: AudioDeviceDirection) -> [AudioDeviceChoice] {
        let defaultChoice = AudioDeviceChoice(
            id: 0, uid: "", name: "System default \(direction.label), follows changes")
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var byteCount: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &byteCount) == noErr else {
            return [defaultChoice]
        }
        var ids = [AudioDeviceID](
            repeating: 0, count: Int(byteCount) / MemoryLayout<AudioDeviceID>.size)
        guard !ids.isEmpty,
            AudioObjectGetPropertyData(system, &address, 0, nil, &byteCount, &ids) == noErr else {
            return [defaultChoice]
        }
        let found = ids.compactMap { id -> AudioDeviceChoice? in
            var streams = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams, mScope: direction.scope,
                mElement: kAudioObjectPropertyElementMain)
            var streamBytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamBytes) == noErr,
                streamBytes > 0,
                let uid = stringProperty(id, kAudioDevicePropertyDeviceUID), !uid.isEmpty,
                let name = stringProperty(id, kAudioObjectPropertyName), !name.isEmpty else {
                return nil
            }
            return AudioDeviceChoice(id: id, uid: uid, name: name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return [defaultChoice] + found
    }

    public static func resolve(
        _ uid: String, for direction: AudioDeviceDirection
    ) throws -> AudioDeviceID? {
        guard !uid.isEmpty else { return nil }
        guard let choice = choices(for: direction).first(where: { $0.uid == uid }) else {
            throw AudioDeviceCatalogError.unavailable(direction)
        }
        return choice.id
    }

    public static func inputChannelPairCount(_ uid: String) -> Int {
        guard !uid.isEmpty,
            let id = try? resolve(uid, for: .input) else { return 0 }
        var streamAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &streamAddress, 0, nil, &size) == noErr,
            size >= UInt32(MemoryLayout<AudioStreamID>.size) else { return 0 }
        var streams = [AudioStreamID](repeating: 0,
            count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(id, &streamAddress, 0, nil,
            &size, &streams) == noErr else { return 0 }
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyVirtualFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(streams[0], &formatAddress, 0, nil,
            &size, &format) == noErr,
            format.mChannelsPerFrame > 2,
            format.mFormatID == kAudioFormatLinearPCM,
            format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
            format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
            format.mBitsPerChannel == 32,
            format.mSampleRate == Double(Wire.sampleRate) else { return 0 }
        return Int(format.mChannelsPerFrame / 2)
    }

    public static func outputChannelPairCount(_ uid: String) -> Int {
        outputChannelCount(uid) / 2
    }

    static func captureRoutes(streamChannelCounts: [Int]) -> [SystemCaptureChannelRoute] {
        guard streamChannelCounts.allSatisfy({ $0 >= 0 && $0.isMultiple(of: 2) }) else {
            return []
        }
        var routes = [SystemCaptureChannelRoute]()
        var channelOffset = 0
        for (stream, channels) in streamChannelCounts.enumerated() {
            for pair in 0..<(channels / 2) {
                routes.append(SystemCaptureChannelRoute(pair: (channelOffset / 2) + pair,
                    stream: UInt(stream), pairInStream: pair))
            }
            channelOffset += channels
        }
        return routes
    }

    public static func systemCaptureRoutes(_ uid: String) -> [SystemCaptureChannelRoute] {
        guard !uid.isEmpty, let id = try? resolve(uid, for: .output) else { return [] }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
            size >= UInt32(MemoryLayout<AudioStreamID>.size) else { return [] }
        var streams = [AudioStreamID](repeating: 0,
            count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &streams) == noErr else {
            return []
        }
        var counts = [Int]()
        for stream in streams {
            var formatAddress = AudioObjectPropertyAddress(
                mSelector: kAudioStreamPropertyVirtualFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var format = AudioStreamBasicDescription()
            var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard AudioObjectGetPropertyData(stream, &formatAddress, 0, nil,
                &formatSize, &format) == noErr else { return [] }
            counts.append(Int(format.mChannelsPerFrame))
        }
        return captureRoutes(streamChannelCounts: counts)
    }

    static func outputChannelCount(_ uid: String) -> Int {
        guard !uid.isEmpty,
            let id = try? resolve(uid, for: .output) else { return 0 }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
            size >= UInt32(MemoryLayout<AudioStreamID>.size) else { return 0 }
        var streams = [AudioStreamID](repeating: 0,
            count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &streams) == noErr else {
            return 0
        }
        var totalChannels = 0
        for stream in streams {
            var formatAddress = AudioObjectPropertyAddress(
                mSelector: kAudioStreamPropertyVirtualFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var format = AudioStreamBasicDescription()
            var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard AudioObjectGetPropertyData(stream, &formatAddress, 0, nil,
                &formatSize, &format) == noErr else { return 0 }
            totalChannels += Int(format.mChannelsPerFrame)
        }
        return totalChannels
    }

    static func activeIdentity(_ uid: String, for direction: AudioDeviceDirection) -> String {
        if !uid.isEmpty {
            guard let selected = choices(for: direction).first(where: { $0.uid == uid }) else {
                return "missing:\(uid)"
            }
            return "\(uid):\(selected.id)"
        }
        var address = AudioObjectPropertyAddress(
            mSelector: direction == .input ? kAudioHardwarePropertyDefaultInputDevice
                : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &id)
        return status == noErr ? "default:\(id)" : "default:unavailable"
    }

    private static func stringProperty(
        _ id: AudioDeviceID, _ selector: AudioObjectPropertySelector, maximumCharacters: Int? = nil
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString = "" as CFString
        var byteCount = UInt32(MemoryLayout<CFString>.size)
        let result = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &byteCount, $0)
        }
        guard result == noErr else { return nil }
        if let maximumCharacters {
            guard byteCount == MemoryLayout<CFString>.size, CFStringGetLength(value) <= maximumCharacters else { return nil }
        }
        return value as String
    }
}

public struct AudioDeviceReportFormat: Equatable, Sendable {
    public let sampleRate: Double
    public let channels: Int
    public let bitsPerChannel: Int
    public let encoding: String

    private static let maximumSampleRate = 1_000_000.0
    private static let maximumChannels = 4096
    private static let maximumBitsPerChannel = 128
    /// Display validation only; this does not establish a usable RemSound audio route.
    public var isValidForReport: Bool {
        sampleRate.isFinite && sampleRate >= 1 && sampleRate <= Self.maximumSampleRate &&
            (1...Self.maximumChannels).contains(channels) && (0...Self.maximumBitsPerChannel).contains(bitsPerChannel)
    }

    public init(sampleRate: Double, channels: Int, bitsPerChannel: Int, encoding: String) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerChannel = bitsPerChannel
        self.encoding = encoding
    }
}

public struct AudioDeviceReportItem: Equatable, Sendable {
    public let uid: String
    public let name: String
    public let isDefault: Bool
    public let formats: [AudioDeviceReportFormat?]

    public init(uid: String, name: String, isDefault: Bool, formats: [AudioDeviceReportFormat?]) {
        self.uid = uid
        self.name = name
        self.isDefault = isDefault
        self.formats = formats
    }
}

public struct AudioDeviceReportSnapshot: Equatable, Sendable {
    public let inputs: [AudioDeviceReportItem]
    public let outputs: [AudioDeviceReportItem]

    public init(inputs: [AudioDeviceReportItem], outputs: [AudioDeviceReportItem]) {
        self.inputs = inputs
        self.outputs = outputs
    }
}

struct AudioDeviceReportSource {
    var ids: () throws -> [UInt32]
    var defaultID: (AudioDeviceDirection) -> UInt32?
    var streams: (UInt32, AudioDeviceDirection) throws -> [UInt32]
    var uid: (UInt32) -> String?
    var name: (UInt32) -> String?
    var format: (UInt32) -> AudioDeviceReportFormat?
}

private enum AudioDeviceReportError: LocalizedError {
    case refused, unavailable
    var errorDescription: String? {
        self == .refused ? "Hardware enumeration was not permitted." :
            "Core Audio metadata is unavailable or exceeds the report limits. No partial device report was produced."
    }
}

extension AudioDeviceCatalog {
    private static let reportMaximumDevices = 1024
    private static let reportMaximumStreamsPerDirection = 256
    private static let reportMaximumTotalStreams = 8192
    private static let reportMaximumMetadataCharacters = 4096

    /// Reads metadata only. Callers must permit hardware enumeration before constructing its source.
    public static func reportSnapshot(allowHardwareEnumeration: Bool = false) throws -> AudioDeviceReportSnapshot {
        try reportSnapshot(allowHardwareEnumeration: allowHardwareEnumeration, makeSource: reportNativeSource)
    }

    static func reportSnapshot(allowHardwareEnumeration: Bool,
        makeSource: () -> AudioDeviceReportSource) throws -> AudioDeviceReportSnapshot {
        guard allowHardwareEnumeration else { throw AudioDeviceReportError.refused }
        let source = makeSource()
        let ids = try source.ids()
        guard ids.count <= reportMaximumDevices, !ids.contains(0), Set(ids).count == ids.count else {
            throw AudioDeviceReportError.unavailable
        }
        let inputDefault = source.defaultID(.input), outputDefault = source.defaultID(.output)
        var inputs: [AudioDeviceReportItem] = [], outputs: [AudioDeviceReportItem] = []
        var inputUIDs = Set<String>(), outputUIDs = Set<String>(), totalStreams = 0
        for id in ids {
            let incoming = try source.streams(id, .input), outgoing = try source.streams(id, .output)
            for streams in [incoming, outgoing] {
                guard streams.count <= reportMaximumStreamsPerDirection,
                    !streams.contains(0), Set(streams).count == streams.count else {
                    throw AudioDeviceReportError.unavailable
                }
            }
            totalStreams += incoming.count + outgoing.count
            guard totalStreams <= reportMaximumTotalStreams else { throw AudioDeviceReportError.unavailable }
            if incoming.isEmpty && outgoing.isEmpty { continue }
            guard let uid = source.uid(id), !uid.isEmpty, uid.utf16.count <= reportMaximumMetadataCharacters,
                let name = source.name(id), !name.isEmpty, name.utf16.count <= reportMaximumMetadataCharacters else {
                throw AudioDeviceReportError.unavailable
            }
            if !incoming.isEmpty {
                guard inputUIDs.insert(uid).inserted else { throw AudioDeviceReportError.unavailable }
                inputs.append(.init(uid: uid, name: name, isDefault: id == inputDefault,
                    formats: incoming.map(source.format)))
            }
            if !outgoing.isEmpty {
                guard outputUIDs.insert(uid).inserted else { throw AudioDeviceReportError.unavailable }
                outputs.append(.init(uid: uid, name: name, isDefault: id == outputDefault,
                    formats: outgoing.map(source.format)))
            }
        }
        return .init(inputs: inputs, outputs: outputs)
    }

    static func readReportArray(maximumCount: Int, size: () -> UInt32?,
        read: (UnsafeMutableRawPointer, inout UInt32) -> Bool) -> [UInt32]? {
        let wordBytes = MemoryLayout<UInt32>.size
        guard maximumCount > 0, maximumCount <= reportMaximumDevices, let bytes = size(),
            bytes <= maximumCount * wordBytes, bytes.isMultiple(of: UInt32(wordBytes)) else { return nil }
        if bytes == 0 { return [] }
        var data = Data(count: Int(bytes)), received = bytes
        let succeeded = data.withUnsafeMutableBytes { buffer in read(buffer.baseAddress!, &received) }
        guard succeeded, received <= bytes, received.isMultiple(of: UInt32(wordBytes)) else { return nil }
        return data.withUnsafeBytes { buffer in
            stride(from: 0, to: Int(received), by: wordBytes).map { buffer.loadUnaligned(fromByteOffset: $0, as: UInt32.self) }
        }
    }

    static func decodeReportFormat(_ format: AudioStreamBasicDescription) -> AudioDeviceReportFormat? {
        guard format.mFormatID != 0 else { return nil }
        var encoding: String
        if format.mFormatID == kAudioFormatLinearPCM {
            encoding = format.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? "float PCM" : "integer PCM"
            if format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 { encoding += ", non-interleaved" }
        } else { encoding = String(format: "format 0x%08x", format.mFormatID) }
        let value = AudioDeviceReportFormat(sampleRate: format.mSampleRate, channels: Int(format.mChannelsPerFrame),
            bitsPerChannel: Int(format.mBitsPerChannel), encoding: encoding)
        return value.isValidForReport ? value : nil
    }

    private static func reportNativeSource() -> AudioDeviceReportSource {
        .init(ids: {
            guard let ids = reportNativeArray(AudioObjectID(kAudioObjectSystemObject),
                selector: kAudioHardwarePropertyDevices, scope: kAudioObjectPropertyScopeGlobal,
                maximumCount: reportMaximumDevices) else { throw AudioDeviceReportError.unavailable }
            return ids
        }, defaultID: { direction in
            var address = AudioObjectPropertyAddress(
                mSelector: direction == .input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var id = AudioDeviceID(kAudioObjectUnknown), bytes = UInt32(MemoryLayout<AudioDeviceID>.size)
            guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &bytes, &id) == noErr,
                bytes == MemoryLayout<AudioDeviceID>.size, id != kAudioObjectUnknown else { return nil }
            return id
        }, streams: { id, direction in
            guard let streams = reportNativeArray(id, selector: kAudioDevicePropertyStreams,
                scope: direction.scope, maximumCount: reportMaximumStreamsPerDirection) else { throw AudioDeviceReportError.unavailable }
            return streams
        }, uid: { stringProperty($0, kAudioDevicePropertyDeviceUID, maximumCharacters: reportMaximumMetadataCharacters) },
        name: { stringProperty($0, kAudioObjectPropertyName, maximumCharacters: reportMaximumMetadataCharacters) },
        format: { stream in
            var address = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyVirtualFormat,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var format = AudioStreamBasicDescription(), bytes = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard AudioObjectGetPropertyData(stream, &address, 0, nil, &bytes, &format) == noErr,
                bytes == MemoryLayout<AudioStreamBasicDescription>.size else { return nil }
            return decodeReportFormat(format)
        })
    }

    private static func reportNativeArray(_ object: AudioObjectID, selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope, maximumCount: Int) -> [UInt32]? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        return readReportArray(maximumCount: maximumCount, size: {
            var bytes: UInt32 = 0
            return AudioObjectGetPropertyDataSize(object, &address, 0, nil, &bytes) == noErr ? bytes : nil
        }, read: { pointer, bytes in AudioObjectGetPropertyData(object, &address, 0, nil, &bytes, pointer) == noErr })
    }
}
