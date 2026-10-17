import Foundation

/// An explicit offline replay request; constructing launch options performs no file or runtime work.
public struct SimulationReplayOptions: Equatable, Sendable {
    public let recording: URL
    public let outputDirectory: URL?
    public let seconds: Double
    public let stream: Int
    public let oneWayMs: Double?
}
