import Foundation

public enum SimulationRecordingFile {
    public static let maximumBytes = 16 * 1024 * 1024
    public enum Failure: Error, LocalizedError {
        case unavailable
        public var errorDescription: String? { "The replay recording is unavailable, changed while reading, or exceeds the supported bounds." }
    }
    /// Only a bounded stable regular file is read. No settings, profiles or credential provider is consulted.
    public static func read(_ url: URL) throws -> String { try read(url, beforeFinal: nil) }
    static func read(_ url: URL, beforeFinal: (() throws -> Void)?) throws -> String {
        do {
            let bytes = try StableRegularFile.read(url, maximumBytes: maximumBytes, beforeFinal: beforeFinal)
            guard let text = String(data: bytes, encoding: .utf8) else { throw Failure.unavailable }
            return text
        } catch { throw Failure.unavailable }
    }
}
