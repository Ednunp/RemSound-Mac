import Foundation

// All observations run on the session worker. Percentiles retain only recent samples;
// the count, mean and extrema cover the entire reporting interval.
struct AudioIntervalDistribution {
    struct Snapshot {
        let count: Int
        let minimum: Double
        let mean: Double
        let maximum: Double
        let recentP50: Double
        let recentP95: Double
        let recentP99: Double
        let percentileSamples: Int
    }
    private var recent: [Double]
    private var next = 0, retained = 0, count = 0
    private var sum = 0.0, minimum = Double.infinity, maximum = 0.0

    init(capacity: Int = 512) { recent = .init(repeating: 0, count: max(1, capacity)) }
    mutating func note(_ value: Double) {
        guard value.isFinite, value >= 0 else { return }
        count += 1
        sum += value
        minimum = min(minimum, value)
        maximum = max(maximum, value)
        recent[next] = value
        next = (next + 1) % recent.count
        retained = min(retained + 1, recent.count)
    }
    mutating func take() -> Snapshot? {
        guard count > 0 else { return nil }
        let sorted = recent.prefix(retained).sorted()
        func percentile(_ fraction: Double) -> Double {
            sorted[max(0, Int(ceil(Double(retained) * fraction)) - 1)]
        }
        let report = Snapshot(count: count, minimum: minimum, mean: sum / Double(count),
                              maximum: maximum, recentP50: percentile(0.50), recentP95: percentile(0.95),
                              recentP99: percentile(0.99), percentileSamples: retained)
        next = 0; retained = 0; count = 0
        sum = 0; minimum = .infinity; maximum = 0
        return report
    }
}

struct StreamIntervalDiagnostics {
    struct Snapshot {
        let packets: Int
        let frames: Int
        let copies: Int
        let failures: Int
        let gaps: AudioIntervalDistribution.Snapshot?
        let queue: AudioIntervalDistribution.Snapshot?
    }
    private var gaps = AudioIntervalDistribution(), queue = AudioIntervalDistribution()
    private var lastPacketAt: TimeInterval?
    private var packets = 0, frames = 0, copies = 0, failures = 0

    mutating func notePacket(now: TimeInterval) {
        guard now.isFinite else { return }
        if let previous = lastPacketAt, now >= previous { gaps.note((now - previous) * 1_000) }
        lastPacketAt = now
        packets += 1
    }
    mutating func noteQueue(milliseconds: Double) { queue.note(milliseconds) }
    mutating func noteSend(frames: Int, copies: Int, failures: Int) {
        self.frames += frames; self.copies += copies; self.failures += failures
    }
    mutating func take() -> Snapshot {
        defer { packets = 0; frames = 0; copies = 0; failures = 0 }
        return Snapshot(packets: packets, frames: frames, copies: copies, failures: failures,
                        gaps: gaps.take(), queue: queue.take())
    }
}

struct SentAudioDiagnostics {
    private static let capacity = 128
    private var records: [UInt16: StreamIntervalDiagnostics] = [:]
    private var order: [UInt16] = []
    mutating func note(stream: UInt16, frames: Int, copies: Int, failures: Int, now: TimeInterval) {
        if records[stream] == nil {
            if order.count == Self.capacity { records.removeValue(forKey: order.removeFirst()) }
            order.append(stream)
        }
        records[stream, default: StreamIntervalDiagnostics()].notePacket(now: now)
        records[stream]!.noteSend(frames: frames, copies: copies, failures: failures)
    }
    mutating func take() -> [(stream: UInt16, statistics: StreamIntervalDiagnostics.Snapshot)] {
        order.compactMap { stream in
            let report = records[stream]!.take()
            return report.packets > 0 ? (stream, report) : nil
        }
    }
}
