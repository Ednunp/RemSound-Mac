import Foundation

extension RelayGroupClient {
    public struct ServerInfo: Equatable {
        public let version: String
        public let uptime: TimeInterval
        public let people: Int
        public let groups: Int
        public let placesFree: Int
        public let phones: Int
        public let yourPackets: Int
        public let yourLongestGapMs: Double
        public let yourLongGaps: Int
        public let yourSeconds: Int
        public let receivedAt: TimeInterval
    }
    /// server-v2.16 layout 1: version bytes and a fixed 24-byte little-endian counter block.
    /// Unknown layouts/truncation are ignored; future trailing fields do not change these counters.
    public static func readServerInfo(_ body: [UInt8], receivedAt: TimeInterval) -> ServerInfo? {
        let countersBytes = 24
        guard body.count >= 2, body[0] == 1 else { return nil }
        let at = 2 + Int(body[1])
        guard body.count >= at + countersBytes else { return nil }
        let version = String(decoding: body[2..<at].map { $0 < 128 ? $0 : 63 }, as: UTF8.self)
        return ServerInfo(version: version, uptime: TimeInterval(body.readLE(UInt32.self, at: at)),
                          people: Int(body.readLE(UInt16.self, at: at + 4)),
                          groups: Int(body.readLE(UInt16.self, at: at + 6)),
                          placesFree: Int(body.readLE(UInt16.self, at: at + 8)),
                          phones: Int(body.readLE(UInt16.self, at: at + 10)),
                          yourPackets: Int(min(UInt32(Int32.max), body.readLE(UInt32.self, at: at + 12))),
                          yourLongestGapMs: Double(body.readLE(UInt32.self, at: at + 16)) / 1000,
                          yourLongGaps: Int(body.readLE(UInt16.self, at: at + 20)),
                          yourSeconds: Int(body.readLE(UInt16.self, at: at + 22)), receivedAt: receivedAt)
    }
}
