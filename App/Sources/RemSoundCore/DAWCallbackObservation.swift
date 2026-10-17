import Foundation

// Optional loopback observation. Host callback geometry is not the bridge's
// fixed playback request size, a scheduling measurement or hardware latency.
struct DAWCallbackGeometry: Equatable {
    static let payloadSize = 12
    static let maximumFrames = 1_048_576
    private static let sampleRateRange: ClosedRange<Double> = 8_000...768_000
    let sampleRate: Double
    let frames: Int
    var nominalBlockDurationMs: Double { Double(frames)*1000/sampleRate }
    init?(payload: Data) {
        guard payload.count == Self.payloadSize else { return nil }
        let rate = Double(bitPattern: payload.u64(0)), frames = Int(payload.u32(8))
        guard rate.isFinite, Self.sampleRateRange.contains(rate),
            (1...Self.maximumFrames).contains(frames) else { return nil }
        self.sampleRate = rate
        self.frames = frames
    }
}

struct DAWCallbackObservation {
    private static let lifetime: TimeInterval = 3
    private var value: DAWCallbackGeometry?
    private var seen: TimeInterval = -.infinity
    mutating func observe(_ payload: Data, now: TimeInterval) {
        guard now.isFinite, let geometry = DAWCallbackGeometry(payload: payload) else { return }
        value = geometry
        seen = now
    }
    func geometry(now: TimeInterval) -> DAWCallbackGeometry? {
        guard now.isFinite, now >= seen, now - seen < Self.lifetime else { return nil }
        return value
    }
    func logDescription(now: TimeInterval, workerRequestFrames: Int?) -> String {
        let request = workerRequestFrames.map(String.init) ?? "not requested"
        guard let geometry = geometry(now: now) else {
            return "host callback geometry not measured or stale; bridge worker request \(request) frames."
        }
        return "host callback \(geometry.frames) frames; nominal host rate \(String(format: "%.3f", geometry.sampleRate)) Hz; "
            + "derived block duration \(String(format: "%.3f", Double(geometry.frames) * 1000 / geometry.sampleRate)) ms; "
            + "bridge worker request \(request) frames. Host scheduling and hardware delay are not measured."
    }
}
