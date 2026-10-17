import Foundation

/// Capture-to-echo timing and the no-audio safety timeout. Used only on the session queue; never on an audio callback.
public struct SelfMonitorTiming {
    static let capacity = 512
    static let timeoutUs: Int64 = 5_000_000
    public struct Measurement {
        public let count: Int
        public let returnedCount: Int
        public let medianMs: Double
        public let longestMs: Double
    }
    private struct Key: Hashable { let stream: UInt16; let sequence: UInt32 }
    private struct Entry { var captured: Int64?; var arrived: Int64?; var matched = false }
    private struct Sample { let stream: UInt16; let delayUs: Int64 }
    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []
    private var samples: [Sample] = []
    private var returnedCounts: [UInt16: Int] = [:]
    private var lastEchoUs: Int64 = 0
    public private(set) var enabled = false
    public private(set) var echoes = 0
    var pendingCount: Int { entries.count }
    public init() {}

    public static func refusal(onServer: Bool, sending: Bool, receiving: Bool) -> String? {
        if !onServer { return "Connect to a server before testing round trip." }
        if !sending { return "Turn on audio sending before testing round trip." }
        if !receiving { return "Turn on Receive before testing round trip." }
        return nil
    }

    public mutating func start(nowUs: Int64) {
        self = SelfMonitorTiming()
        enabled = true
        lastEchoUs = nowUs
    }
    public mutating func stop() { self = SelfMonitorTiming() }
    public func expired(nowUs: Int64) -> Bool { enabled && nowUs - lastEchoUs >= Self.timeoutUs }

    public mutating func noteSent(stream: UInt16, sequence: UInt32, capturedUs: Int64) {
        guard enabled else { return }
        update(Key(stream: stream, sequence: sequence), captured: capturedUs, arrived: nil)
    }
    /// Called only after the receive decoder authenticates and accepts the echoed audio.
    public mutating func noteEcho(stream: UInt16, sequence: UInt32, arrivedUs: Int64) {
        guard enabled else { return }
        lastEchoUs = arrivedUs
        echoes += 1
        if returnedCounts[stream] != nil || returnedCounts.count < Self.capacity {
            returnedCounts[stream, default: 0] += 1
        }
        update(Key(stream: stream, sequence: sequence), captured: nil, arrived: arrivedUs)
    }
    private mutating func update(_ key: Key, captured: Int64?, arrived: Int64?) {
        if entries[key] == nil {
            if order.count >= Self.capacity { entries[order.removeFirst()] = nil }
            order.append(key)
            entries[key] = Entry()
        }
        guard var entry = entries[key], !entry.matched else { return }
        if let captured { entry.captured = captured }
        if let arrived { entry.arrived = arrived }
        if let captured = entry.captured, let arrived = entry.arrived {
            entry.matched = true
            let delay = arrived - captured
            if delay >= 0 && delay < Self.timeoutUs {
                if samples.count >= Self.capacity { samples.removeFirst() }
                samples.append(Sample(stream: key.stream, delayUs: delay))
            }
        }
        entries[key] = entry
    }
    public mutating func takeMeasurements() -> [UInt16: Measurement] {
        defer {
            samples.removeAll(keepingCapacity: true)
            returnedCounts.removeAll(keepingCapacity: true)
            echoes = 0
        }
        return Dictionary(grouping: samples, by: \.stream).mapValues { values in
            let delays = values.map(\.delayUs).sorted()
            let middle = delays.count / 2
            let median = delays.count.isMultiple(of: 2)
                ? Double(delays[middle - 1] + delays[middle]) / 2 : Double(delays[middle])
            return Measurement(count: delays.count, returnedCount: returnedCounts[values[0].stream] ?? 0,
                               medianMs: median / 1000, longestMs: Double(delays.last!) / 1000)
        }
    }
}
