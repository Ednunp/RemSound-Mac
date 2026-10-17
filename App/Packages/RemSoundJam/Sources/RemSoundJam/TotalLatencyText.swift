import Foundation

/// The Total latency box under the receive buffer settings (Windows MainForm FormatMeasuredLatency): the jitter buffer,
/// what the sound cards, hardware and network add, and the one-way total, from the quickest complete path in. The
/// buffer figure is the setting, or the depth the sound actually plays at when that is lower. A figure changes only
/// once it has moved 3 ms, so the box is not forever rewriting itself.
public enum TotalLatencyText {
    public struct Journey: Equatable, Sendable {
        /// What sits in the receive buffer now.
        public var bufferMs: Double
        /// The whole one-way path, when every part of it is known.
        public var totalMs: Double?
        public init(bufferMs: Double, totalMs: Double?) { self.bufferMs = bufferMs; self.totalMs = totalMs }
    }
    public struct Figures: Equatable, Sendable {
        public var bufferMs: Double
        public var hardwareMs: Double
        public var totalMs: Double
    }
    public static let hysteresisMs = 3.0

    /// The quickest complete journey's figures; nil when none is complete.
    public static func figures(setMs: Int, journeys: [Journey]) -> Figures? {
        let complete = journeys.compactMap { j in j.totalMs.map { (buffer: j.bufferMs, total: $0) } }
        guard let best = complete.min(by: { $0.total < $1.total }) else { return nil }
        let hardware = max(0, best.total - best.buffer)
        let buffer = min(Double(setMs), best.buffer)
        return .init(bufferMs: buffer, hardwareMs: hardware, totalMs: buffer + hardware)
    }

    /// The new figures, unless the shown ones are within 3 ms of them: then the shown ones stay.
    public static func steady(shown: Figures?, new: Figures?) -> Figures? {
        guard let shown, let new else { return new }
        let moved = abs(shown.hardwareMs - new.hardwareMs) >= hysteresisMs || abs(shown.totalMs - new.totalMs) >= hysteresisMs
            || abs(shown.bufferMs - new.bufferMs) >= hysteresisMs
        return moved ? new : shown
    }

    public static func text(setMs: Int, receiving: Bool, figures: Figures?) -> String {
        guard receiving else { return "Jitter buffer \(setMs) ms, not receiving." }
        guard let f = figures else {
            return "Jitter buffer \(setMs) ms. The sound card and hardware figures, and the total, appear once every part of the path is known."
        }
        return "Jitter buffer \(Int(f.bufferMs.rounded())) ms. Sound card and hardware add \(Int(f.hardwareMs.rounded())) ms. "
            + "Total latency approximately \(Int(f.totalMs.rounded())) ms one way."
    }
}
