import Foundation

// The peer echoes our monotonic tick in its heartbeat reply. This measures a round trip
// without comparing clocks on different computers or accepting another peer's relay ping.
struct HeartbeatTiming {
    static let pingInterval: TimeInterval = 1
    static let healthyWindowMs: UInt64 = 2_000
    static let unreachableWindowMs: UInt64 = 5_000
    enum State { case pending, healthy, stale, unreachable }
    struct Health {
        let state: State
        let milliseconds: Int?
        let ageMs: UInt64?
        var currentRTT: Double? { state == .healthy ? milliseconds.map(Double.init) : nil }
        var status: String {
            switch state {
            case .healthy:
                return milliseconds.map { "ping \(Int((Double($0)/5).rounded())*5) ms" } ?? "ping pending"
            case .stale, .unreachable:
                // Whole seconds keep the focused peer row stable between age boundaries.
                let age=ageMs.map { String($0/1000)+".0 s" } ?? "unknown"
                return "ping \(state == .stale ? "stale" : "unreachable") \(age)"
            case .pending: return "ping pending"
            }
        }
    }
    private struct Sample {
        var milliseconds: Int
        var seenTickMs: UInt64
    }

    private var recentPingTicks: [UInt64] = []
    private var samples: [String: Sample] = [:]
    private var firstPings: [String: UInt64] = [:]
    private let maximumRecentPings = 16
    private let maximumRoundTripMs: UInt64 = 30_000
    private let sampleLifetimeMs: UInt64 = 5_000

    mutating func sent(tickMs: UInt64, selected addresses: [String] = []) {
        for address in addresses where firstPings[address] == nil { firstPings[address] = tickMs }
        recentPingTicks.append(tickMs)
        if recentPingTicks.count > maximumRecentPings { recentPingTicks.removeFirst() }
    }

    @discardableResult
    mutating func receivedPong(from address: String, echoTickMs: UInt64,
        nowTickMs: UInt64) -> Bool {
        guard recentPingTicks.contains(echoTickMs), nowTickMs >= echoTickMs,
            nowTickMs - echoTickMs <= maximumRoundTripMs else { return false }
        let measured = Int(nowTickMs - echoTickMs)
        let smoothed = samples[address].map {
            ($0.milliseconds * 7 + measured * 3 + 5) / 10
        } ?? measured
        samples[address] = Sample(milliseconds: smoothed, seenTickMs: nowTickMs)
        return true
    }

    func range(selected addresses: [String], nowTickMs: UInt64) -> ClosedRange<Int>? {
        let current = addresses.compactMap { address -> Int? in
            guard let sample = samples[address], nowTickMs >= sample.seenTickMs,
                nowTickMs - sample.seenTickMs <= sampleLifetimeMs else { return nil }
            return sample.milliseconds
        }
        guard let minimum = current.min(), let maximum = current.max() else { return nil }
        return minimum...maximum
    }

    func health(for address: String, nowTickMs: UInt64) -> Health {
        if let sample=samples[address], nowTickMs >= sample.seenTickMs {
            let age=nowTickMs-sample.seenTickMs
            let state: State = age <= Self.healthyWindowMs ? .healthy
                : age <= Self.unreachableWindowMs ? .stale : .unreachable
            return .init(state:state,milliseconds:sample.milliseconds,ageMs:age)
        }
        if let first=firstPings[address], nowTickMs >= first,
            nowTickMs-first > Self.unreachableWindowMs {
            return .init(state:.unreachable,milliseconds:nil,ageMs:nowTickMs-first)
        }
        return .init(state:.pending,milliseconds:nil,ageMs:nil)
    }
    mutating func forget(_ address: String) {
        samples.removeValue(forKey: address); firstPings.removeValue(forKey: address)
    }
}
