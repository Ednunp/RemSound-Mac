import Foundation

public enum PushToTalkCapturePath: String, Codable, CaseIterable {
    case input, systemAudio, both
}

public enum PushToTalkTrigger: String, Codable, CaseIterable {
    case key, level
}

public enum PushToTalkSendLane: CaseIterable {
    case inputCapture, systemCapture, plugin
}

/// Pure gate configuration; persistence and native control ownership belong to Core/App.
public struct PushToTalkGateConfiguration: Equatable {
    public static let minimumLevelDb = -70
    public static let maximumLevelDb = -10
    public static let defaultLevelDb = -40
    public var enabled = false
    public var capturePath: PushToTalkCapturePath = .both
    public var trigger: PushToTalkTrigger = .key
    public var levelDb = defaultLevelDb
    public var bypassForRecording = false
    public var bypassForPlugin = false
    public init() {}

    public var levelLinear: Float {
        Float(pow(10, Double(max(Self.minimumLevelDb, min(Self.maximumLevelDb, levelDb))) / 20))
    }
}

/// A lane's fade is independent of every other capture/plugin stream.
public struct PushToTalkLaneState {
    public let kind: PushToTalkSendLane
    public private(set) var gain: Float = 1
    public init(_ kind: PushToTalkSendLane) { self.kind = kind }
    fileprivate mutating func moveGain(toward target: Float) {
        if gain < target { gain = min(target, gain + PushToTalkAudioGate.fadeStep) }
        else if gain > target { gain = max(target, gain - PushToTalkAudioGate.fadeStep) }
    }
}

/// Worker-owned audio policy. The caller supplies preallocated buffers and one shared 48 kHz frame clock.
/// This never allocates a scratch buffer, installs a hook, opens a device or logs from a callback.
public struct PushToTalkAudioGate {
    public static let sampleRate = 48_000
    public static let channels = 2
    public static let fadeFrames = 240
    public static let hangFrames: Int64 = 24_000
    fileprivate static let fadeStep = Float(1) / Float(fadeFrames)
    public private(set) var configuration = PushToTalkGateConfiguration()
    private var keyTalking = false
    private var lastLoudFrame: Int64?
    private var observedOpen = false
    private var opens: UInt64 = 0, closes: UInt64 = 0
    public init() {}

    /// Settings changes retire old level history and held keys; lane fades continue smoothly.
    public mutating func configure(_ value: PushToTalkGateConfiguration) {
        configuration = value
        keyTalking = false
        lastLoudFrame = nil
    }
    public mutating func setKeyTalking(_ value: Bool) { keyTalking = value }
    public var recordsUngated: Bool { !configuration.enabled || configuration.bypassForRecording }

    public func holds(_ lane: PushToTalkSendLane) -> Bool {
        guard configuration.enabled else { return false }
        switch lane {
        case .inputCapture: return configuration.capturePath != .systemAudio
        case .systemCapture: return configuration.capturePath != .input
        case .plugin: return !configuration.bypassForPlugin
        }
    }
    public func isOpen(atFrame frame: Int64) -> Bool {
        !configuration.enabled || (configuration.trigger == .key ? keyTalking : levelOpen(atFrame: frame))
    }
    private func levelOpen(atFrame frame: Int64) -> Bool {
        guard let lastLoudFrame else { return false }
        let elapsed = frame.subtractingReportingOverflow(lastLoudFrame)
        // Like Windows, overlapping lane blocks can start before the latest shared loud frame.
        return !elapsed.overflow && elapsed.partialValue <= Self.hangFrames
    }
    private mutating func noteState(_ value: Bool) {
        guard value != observedOpen else { return }
        observedOpen = value
        if value { opens &+= 1 } else { closes &+= 1 }
    }
    public mutating func takeTransitions() -> (opens: UInt64, closes: UInt64) {
        defer { opens = 0; closes = 0 }
        return (opens, closes)
    }

    /// Stereo normalized samples, ending at blockEndFrame (exclusive), from the caller's shared clock.
    /// Buffers must be distinct or have the same base address; partial overlap is not supported.
    /// Returns false for invalid geometry/time without changing output or gate/lane state.
    @discardableResult public mutating func apply(lane: inout PushToTalkLaneState,
        input: UnsafeBufferPointer<Float>, output: UnsafeMutableBufferPointer<Float>,
        blockEndFrame: Int64) -> Bool {
        guard input.count.isMultiple(of: Self.channels), output.count >= input.count else { return false }
        let frames = input.count / Self.channels
        guard frames > 0 else { return true }
        let start = blockEndFrame.subtractingReportingOverflow(Int64(frames))
        guard !start.overflow else { return false }
        let held = holds(lane.kind)
        var target = true, openFrom = 0
        if held {
            if configuration.trigger == .key { target = keyTalking }
            else {
                let openAtStart = levelOpen(atFrame: start.partialValue)
                if lane.kind == .plugin {
                    target = openAtStart || levelOpen(atFrame: blockEndFrame)
                } else {
                    let threshold = configuration.levelLinear
                    var first: Int?, last: Int?
                    // Inspect before writing so an in-place destination cannot affect the trigger scan.
                    for frame in 0..<frames {
                        let left = input[Self.channels * frame], right = input[Self.channels * frame + 1]
                        let peak = max(left.isFinite ? abs(left) : 0, right.isFinite ? abs(right) : 0)
                        guard peak >= threshold else { continue }
                        if first == nil { first = frame }
                        last = frame
                    }
                    if let last {
                        let loud = start.partialValue + Int64(last + 1)
                        lastLoudFrame = max(lastLoudFrame ?? loud, loud)
                    }
                    if openAtStart { target = true }
                    else if let first { target = true; openFrom = first }
                    else { target = false }
                    noteState(target || levelOpen(atFrame: blockEndFrame))
                }
            }
            if configuration.trigger == .key && lane.kind != .plugin { noteState(target) }
        }
        for frame in 0..<frames {
            lane.moveGain(toward: target && frame >= openFrom ? 1 : 0)
            let left = input[Self.channels * frame], right = input[Self.channels * frame + 1]
            output[Self.channels * frame] = (left.isFinite ? left : 0) * lane.gain
            output[Self.channels * frame + 1] = (right.isFinite ? right : 0) * lane.gain
        }
        return true
    }
}
