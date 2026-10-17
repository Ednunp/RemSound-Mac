import AudioToolbox
import AudioSupport
import CoreAudio
import Foundation
import RemSoundJam

/// The processes Core Audio has sound clients for, this app's own left out: their process objects and bundle IDs
/// (empty where a process has none).
public enum AudioProcesses {
    public static func snapshot() -> [(id: AudioObjectID, bundleID: String)] {
        func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
            AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
        }
        var listAddress = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
            &listAddress, 0, nil, &size) == noErr else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
        guard !list.isEmpty else { return [] }
        let listStatus = list.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size,
                buffer.baseAddress!)
        }
        guard listStatus == noErr else { return [] }
        return list.compactMap { id in
            var pidAddress = address(kAudioProcessPropertyPID)
            var pid = Int32(0)
            var pidSize = UInt32(MemoryLayout<Int32>.size)
            guard AudioObjectGetPropertyData(id, &pidAddress, 0, nil, &pidSize, &pid) == noErr, pid != getpid() else {
                return nil
            }
            var bundleAddress = address(kAudioProcessPropertyBundleID)
            var bundle: CFString = "" as CFString
            var bundleSize = UInt32(MemoryLayout<CFString>.stride)
            let status = withUnsafeMutablePointer(to: &bundle) {
                AudioObjectGetPropertyData(id, &bundleAddress, 0, nil, &bundleSize, $0)
            }
            return (id, status == noErr ? bundle as String : "")
        }
    }
}

final class SystemAudioCapture {
    let samples = StereoRing()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var selectedPair = 0
    private var configuration: SystemTapConfiguration?
    private var capturedOutput: (id: AudioDeviceID, name: String)?

    func configurationDiagnostics() -> [String] {
        guard let configuration else { return ["Core Audio tap setup unavailable: tap is not active."] }
        let aggregate = DeviceConfigurationReader.hardware.snapshot(id: aggregateID,
            name: "RemSound private capture aggregate", direction: .input, presentationLatencySeconds: nil)
        let source = capturedOutput.map {
            DeviceConfigurationReader.hardware.snapshot(id: $0.id, name: $0.name,
                direction: .output, presentationLatencySeconds: nil)
        }
        return configuration.descriptions(aggregate: aggregate, source: source)
    }
    var callbackCaptureCounter: CallbackRateMeter.Counter? {
        guard let configuration else { return nil }
        return CallbackRateMeter.counter(ring: samples, id: configuration.id,
            name: "system/application tap \(configuration.target.description)", formatRate: configuration.format.mSampleRate)
    }

    static func tapDescription(deviceUID: String, excluded: [AudioObjectID],
        stream: UInt = 0) -> CATapDescription {
        if deviceUID.isEmpty {
            return CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        }
        return CATapDescription(excludingProcesses: excluded, deviceUID: deviceUID, stream: stream)
    }

    private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }
    private func excludedProcessIDs() -> [AudioObjectID] {
        var listAddress = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
            &listAddress, 0, nil, &size) == noErr else { return [] }
        var list = [AudioObjectID](repeating: 0,
            count: Int(size) / MemoryLayout<AudioObjectID>.stride)
        guard !list.isEmpty else { return [] }
        let listStatus = list.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                &listAddress, 0, nil, &size, buffer.baseAddress!)
        }
        guard listStatus == noErr else { return [] }
        return list.filter { id in
            var pidAddress = address(kAudioProcessPropertyPID)
            var pid = Int32(0)
            var pidSize = UInt32(MemoryLayout<Int32>.size)
            return AudioObjectGetPropertyData(id, &pidAddress, 0, nil, &pidSize, &pid) == noErr
                && pid == getpid()
        }
    }
    /// `processes`: capture only these (a chosen application's sound, mixed to stereo) instead of an output.
    func start(deviceUID: String = "", stream: UInt = 0, pair: Int = 0, processes: [AudioObjectID]? = nil) throws {
        stop()
        selectedPair = processes == nil ? pair : 0
        guard #available(macOS 14.2, *) else {
            throw ProtocolError.invalid("Mac system audio capture requires macOS 14.2 or newer.")
        }
        do {
            if !deviceUID.isEmpty {
                if let id = try AudioDeviceCatalog.resolve(deviceUID, for: .output) {
                    capturedOutput = (id, AudioDeviceCatalog.choices(for: .output).first { $0.id == id }?.name ?? "Selected output")
                }
            }
            let description = processes.map { CATapDescription(stereoMixdownOfProcesses: $0) }
                ?? Self.tapDescription(deviceUID: deviceUID, excluded: excludedProcessIDs(), stream: stream)
            description.name = processes == nil ? "RemSound system audio capture" : "RemSound application capture"
            description.isPrivate = true
            let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
            guard tapStatus == noErr else {
                throw ProtocolError.invalid("Could not capture Mac system audio (Core Audio error \(tapStatus)).")
            }
            var formatAddress = address(kAudioTapPropertyFormat)
            var tapFormat = AudioStreamBasicDescription()
            var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let formatStatus = AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil,
                &formatSize, &tapFormat)
            guard formatStatus == noErr,
                tapFormat.mFormatID == kAudioFormatLinearPCM,
                tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                tapFormat.mSampleRate == Double(Wire.sampleRate),
                tapFormat.mChannelsPerFrame >= UInt32((pair + 1) * 2),
                tapFormat.mBitsPerChannel == 32 else {
                throw ProtocolError.invalid(
                    "Mac system audio tap must provide 48 kHz floating-point audio with the selected channel pair.")
            }
            var uidAddress = address(kAudioTapPropertyUID)
            var uidSize = UInt32(MemoryLayout<CFString>.stride)
            var tapUID: CFString = "" as CFString
            let uidStatus = withUnsafeMutablePointer(to: &tapUID) {
                AudioObjectGetPropertyData(tapID, &uidAddress, 0, nil, &uidSize, $0)
            }
            guard uidStatus == noErr else {
                throw ProtocolError.invalid("Could not read the Mac system audio tap.")
            }
            let aggregateUID = "me.onj.remsound.system-audio.\(UUID().uuidString)"
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "RemSound system audio input",
                kAudioAggregateDeviceUIDKey: aggregateUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: false,
            ]
            let aggregateStatus = AudioHardwareCreateAggregateDevice(
                aggregateDescription as CFDictionary, &aggregateID)
            guard aggregateStatus == noErr else {
                throw ProtocolError.invalid("Could not create the Mac system audio input (Core Audio error \(aggregateStatus)).")
            }
            var tapsAddress = address(kAudioAggregateDevicePropertyTapList)
            var tapList: CFArray = [tapUID] as CFArray
            let listStatus = withUnsafeMutablePointer(to: &tapList) {
                AudioObjectSetPropertyData(aggregateID, &tapsAddress, 0, nil,
                    UInt32(MemoryLayout<CFArray>.stride), $0)
            }
            guard listStatus == noErr else {
                throw ProtocolError.invalid("Could not attach the Mac system audio tap (Core Audio error \(listStatus)).")
            }
            var aliveAddress = address(kAudioDevicePropertyDeviceIsAlive)
            var streamsAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain)
            let readyBy = Date().addingTimeInterval(2)
            var alive: UInt32 = 0
            var streamBytes: UInt32 = 0
            repeat {
                var aliveSize = UInt32(MemoryLayout<UInt32>.size)
                alive = 0
                streamBytes = 0
                let aliveStatus = AudioObjectGetPropertyData(aggregateID, &aliveAddress,
                    0, nil, &aliveSize, &alive)
                let streamsStatus = AudioObjectGetPropertyDataSize(aggregateID,
                    &streamsAddress, 0, nil, &streamBytes)
                if aliveStatus == noErr, streamsStatus == noErr, alive != 0, streamBytes > 0 {
                    break
                }
                Thread.sleep(forTimeInterval: 0.025)
            } while Date() < readyBy
            guard alive != 0, streamBytes > 0 else {
                throw ProtocolError.invalid("Mac system audio input did not become ready.")
            }
            let context = Unmanaged.passUnretained(self).toOpaque()
            let registration = AudioDeviceCreateIOProcID(aggregateID, { _, _, inputData, inputTime, _, _, context in
                guard let context else { return noErr }
                let capture = Unmanaged<SystemAudioCapture>.fromOpaque(context).takeUnretainedValue()
                let began = rs_callback_begin()
                let buffers = UnsafeMutableAudioBufferListPointer(
                    UnsafeMutablePointer(mutating: inputData))
                guard !buffers.isEmpty else { return noErr }
                let first = buffers[0]
                let leftIndex = capture.selectedPair * 2
                if buffers.count > leftIndex + 1, first.mNumberChannels == 1,
                    buffers[leftIndex + 1].mNumberChannels == 1,
                    let left = buffers[leftIndex].mData,
                    let right = buffers[leftIndex + 1].mData {
                    let frames = min(buffers[leftIndex].mDataByteSize,
                        buffers[leftIndex + 1].mDataByteSize)
                        / UInt32(MemoryLayout<Float>.size)
                    let accepted = rs_ring_write(capture.samples.raw,
                        left.assumingMemoryBound(to: Float.self),
                        right.assumingMemoryBound(to: Float.self), Int(frames))
                    CaptureTimestampObservation.note(ring: capture.samples.raw, began: began,
                        time: inputTime.pointee, frames: Int(frames), accepted: accepted,
                        rate: Double(Wire.sampleRate), origin: UInt32(RS_CAPTURE_PROCESS_TAP))
                    rs_ring_note_callback(capture.samples.raw, began, Int(frames), Double(Wire.sampleRate))
                } else if first.mNumberChannels >= UInt32((capture.selectedPair + 1) * 2),
                    let interleaved = first.mData {
                    let channels = Int(first.mNumberChannels)
                    let frames = Int(first.mDataByteSize)
                        / (MemoryLayout<Float>.size * channels)
                    let accepted = rs_ring_write_interleaved_channel_pair(capture.samples.raw,
                        interleaved.assumingMemoryBound(to: Float.self), channels,
                        capture.selectedPair, frames)
                    CaptureTimestampObservation.note(ring: capture.samples.raw, began: began,
                        time: inputTime.pointee, frames: frames, accepted: accepted,
                        rate: Double(Wire.sampleRate), origin: UInt32(RS_CAPTURE_PROCESS_TAP))
                    rs_ring_note_callback(capture.samples.raw, began, frames, Double(Wire.sampleRate))
                }
                return noErr
            }, context, &ioProcID)
            guard registration == noErr, let ioProcID else {
                throw ProtocolError.invalid(
                    "Could not start Mac system audio capture (Core Audio error \(registration)).")
            }
            let startStatus = AudioDeviceStart(aggregateID, ioProcID)
            guard startStatus == noErr else {
                throw ProtocolError.invalid(
                    "Could not start Mac system audio input (Core Audio error \(startStatus)). Allow System Audio Recording in Privacy settings.")
            }
            let target: SystemTapConfiguration.Target = processes.map { .applications(processCount: $0.count) }
                ?? (deviceUID.isEmpty ? .allOutputs : .device(stream: stream, pair: selectedPair))
            configuration = SystemTapConfiguration(id: UUID(), target: target, format: tapFormat)
        } catch {
            stop()
            throw error
        }
    }
    func stop() {
        configuration = nil
        capturedOutput = nil
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
    deinit { stop() }
}

// Mix on the session worker. System/application taps read available frames immediately;
// selected physical inputs can opt into independent capture-clock keeping.
final class SystemAudioMix {
    let sources: [StereoRing]
    private let inputClocks: CaptureInputClocks?
    init(sources: [StereoRing], captureCallbacks: (() -> [CaptureInputClocks.Callback])? = nil) {
        self.sources = sources
        inputClocks = sources.count > 1 ? captureCallbacks.map {
            CaptureInputClocks(sources: sources, callbacks: $0)
        } : nil
    }
    var available: Int { sources.map(\.available).max() ?? 0 }
    var droppedFrames: Int { sources.reduce(0) { $0 + $1.droppedFrames } }
    var inputClockFigures: [CaptureInputClocks.Figures] { inputClocks?.figures ?? [] }

    private var preparedForSending = false

    @discardableResult
    func prepareForSending() -> Int {
        guard !preparedForSending else { return 0 }
        preparedForSending = true
        guard sources.count > 1 else { return 0 }
        // Inputs start sequentially. Drop setup audio before the first packet so
        // the first device's head start does not remain in the mix for the session.
        return sources.reduce(0) { $0 + $1.discard($1.available) }
    }

    func trimStale(packetFrames: Int) -> Int {
        let trimmed = sources.reduce(0) { count, source in
            count + source.discard(CapturePacer.staleFrames(
                bufferedFrames: source.available, packetFrames: packetFrames))
        }
        if trimmed > 0 { inputClocks?.resetAfterTrim() }
        return trimmed
    }

    func read(_ frames: Int, now: Double = ProcessInfo.processInfo.systemUptime) -> [Float] {
        guard frames > 0 else { return [] }
        if let inputClocks, !inputClocks.prepareRead(frames: frames, now: now, keepingInTime: ClockKeeping.on) {
            return [Float](repeating: 0, count: frames * 2)
        }
        var mixed = [Float](repeating: 0, count: frames * 2)
        for (index, source) in sources.enumerated() {
            let block = inputClocks?.read(sourceAt: index, frames: frames, now: now) ?? source.read(frames)
            for i in mixed.indices { mixed[i] += block[i] }
        }
        for i in mixed.indices { mixed[i] = max(-1, min(1, mixed[i])) }
        return mixed
    }
}

final class SystemAudioCaptureGroup {
    private let isolatedSource: StereoRing?
    init() { isolatedSource = nil }
    init(isolatedSource: StereoRing) {
        self.isolatedSource = isolatedSource
        samples = SystemAudioMix(sources: [isolatedSource])
    }
    private static let maximumSelectedTaps = 16
    private var taps = [SystemAudioCapture]()
    private(set) var samples = SystemAudioMix(sources: [])
    var callbackBudgetDiagnostics: [String] {
        taps.enumerated().map {
            AudioCallbackBudget.describe(ring: $0.element.samples.raw, name: "system/application tap \($0.offset + 1)")
        }
    }
    func configurationDiagnostics() -> [String] { taps.flatMap { $0.configurationDiagnostics() } }
    var callbackCaptureCounters: [CallbackRateMeter.Counter] { taps.compactMap(\.callbackCaptureCounter) }
    var captureTimestampDiagnostics: [String] {
        taps.enumerated().map {
            CaptureTimestampObservation.describe(ring: $0.element.samples.raw,
                name: "system/application tap \($0.offset + 1)")
        }
    }
    // Sending chosen applications (RemSoundJam's AppAudio): one tap on their processes, made again when those change -
    // an application started, or a helper of its began to make sound - so each is caught from its first sound.
    private var applications: [String]?
    private var applicationTap: SystemAudioCapture?
    private var applicationProcesses: [AudioObjectID] = []
    /// What the last start or refresh did, for the log.
    private(set) var lastChange: String?

    /// `applications` (bundle IDs): send those applications' sound, not the outputs'.
    func start(deviceUIDs: [String]?, channelPairs: [String: [Int]] = [:], applications: [String]? = nil) throws {
        stop()
        // Isolated Session fixtures must remain device-free even when application selection restarts capture.
        if let isolatedSource {
            _ = isolatedSource.discard(isolatedSource.available)
            samples = SystemAudioMix(sources: [isolatedSource])
            return
        }
        if let applications {
            self.applications = applications
            let tap = SystemAudioCapture()
            applicationTap = tap
            taps = [tap]
            samples = SystemAudioMix(sources: [tap.samples])
            lastChange = try refreshApplications(force: true)
            return
        }
        let selected = deviceUIDs ?? [""]
        guard !selected.isEmpty else {
            throw ProtocolError.invalid("Choose a system audio output or All Mac outputs.")
        }
        do {
            var seen = Set<String>()
            for uid in selected where seen.insert(uid).inserted {
                if uid.isEmpty {
                    let tap = SystemAudioCapture()
                    try tap.start()
                    taps.append(tap)
                    continue
                }
                let routes = AudioDeviceCatalog.systemCaptureRoutes(uid)
                let requestedPairs = Array(Set(channelPairs[uid] ?? [0])).sorted()
                guard !requestedPairs.isEmpty else {
                    throw ProtocolError.invalid("Choose at least one system output channel pair.")
                }
                for pair in requestedPairs {
                    guard let route = routes.first(where: { $0.pair == pair })
                        ?? (pair == 0 && routes.isEmpty
                            ? SystemCaptureChannelRoute(pair: 0, stream: 0, pairInStream: 0)
                            : nil) else {
                        throw ProtocolError.invalid("The selected system output channel pair is unavailable.")
                    }
                    let tap = SystemAudioCapture()
                    try tap.start(deviceUID: uid, stream: route.stream,
                        pair: route.pairInStream)
                    taps.append(tap)
                    guard taps.count <= Self.maximumSelectedTaps else {
                        throw ProtocolError.invalid("Choose at most 16 system output channel pairs.")
                    }
                }
            }
            samples = SystemAudioMix(sources: taps.map(\.samples))
        } catch {
            stop()
            throw error
        }
    }

    /// Sending applications: the processes they have now, and the tap made again if those changed (nil if not).
    @discardableResult
    func refreshApplications(force: Bool = false) throws -> String? {
        guard let applications, let tap = applicationTap else { return nil }
        let now = AppAudio.processes(for: Set(applications), in: AudioProcesses.snapshot())
        guard force || now != applicationProcesses else { return nil }
        guard !now.isEmpty else {
            tap.stop()
            applicationProcesses = now
            return applications.isEmpty ? "System audio: no application chosen."
                : "System audio: none of the \(applications.count) chosen application(s) is making sound yet; waiting for them."
        }
        try tap.start(processes: now)
        applicationProcesses = now
        return "System audio: capturing \(now.count) sound process(es) of \(applications.joined(separator: ", "))."
    }

    func stop() {
        for tap in taps { tap.stop() }
        taps.removeAll()
        samples = SystemAudioMix(sources: [])
        applications = nil
        applicationTap = nil
        applicationProcesses = []
    }
    deinit { stop() }
}
