import Foundation

/// A throwaway server-version exchange, driven on one queue by elapsed monotonic seconds.
/// It owns no socket, timer, audio, selections or persisted identity. The caller supplies a fresh
/// random client ID and eight-byte group tag, sends returned packets on a separate socket and
/// closes that socket after a result. Cancellation must send the returned goodbyes too.
public final class ServerVersionProbe {
    public static let name = "server check"
    public static let limit: TimeInterval = 3
    public static let olderAfter: TimeInterval = 0.8
    public static let statusWait: TimeInterval = 2
    private static let unansweredHelloInterval: TimeInterval = 0.4
    private static let answeredHelloInterval: TimeInterval = 1
    private static let pingInterval: TimeInterval = 0.1
    private static let goodbyeCopies = 2
    private static let pendingPingLimit = 30
    private static let addressCookieBytes = 16

    public struct Result: Equatable {
        public let answered: Bool
        public let version: String?
        public let roundTripMs: Double?
        public let full: Bool
        public let cancelled: Bool
        public init(answered: Bool, version: String?, roundTripMs: Double?, full: Bool, cancelled: Bool = false) {
            self.answered = answered; self.version = version; self.roundTripMs = roundTripMs
            self.full = full; self.cancelled = cancelled
        }
    }

    public private(set) var result: Result?
    private let server: JamEndpoint
    private let id: [UInt8]
    private let hello: [UInt8]
    private var started = false
    private var lastElapsed: TimeInterval = 0
    private var nextHello: TimeInterval = 0
    private var nextPing: TimeInterval = 0
    private var answeredAt: TimeInterval?
    private var pingedBackAt: TimeInterval?
    private var roundTripMs: Double?
    private var pendingPings: [Int64] = []

    public init(server: JamEndpoint, clientID: UUID, groupTag: [UInt8]) {
        precondition(groupTag.count == JamWire.fingerprintSize)
        self.server = server
        id = JamWire.bytes(of: clientID)
        var name = Array(Self.name.utf8)
        name += [UInt8](repeating: 0, count: RelayGroupClient.nameBytes - name.count)
        hello = JamWire.header(JamWire.Kind.hello.rawValue, version: JamWire.groupVersion) + id + name + groupTag + [0]
    }

    public func tick(at elapsed: TimeInterval) -> [[UInt8]] {
        guard acceptTime(elapsed) else { return [] }
        if expired(at: elapsed) { return finish() }
        var outgoing: [[UInt8]] = []
        if elapsed >= nextHello {
            started = true
            outgoing.append(hello)
            nextHello = elapsed + (answeredAt == nil ? Self.unansweredHelloInterval : Self.answeredHelloInterval)
        }
        if answeredAt != nil, elapsed >= nextPing {
            let stamp = Int64(elapsed * 1_000_000)
            var ping = header(.serverPing)
            ping.appendLE(stamp)
            if pendingPings.count == Self.pendingPingLimit { pendingPings.removeFirst() }
            pendingPings.append(stamp)
            outgoing.append(ping)
            nextPing = elapsed + Self.pingInterval
        }
        return outgoing
    }

    public func receive(_ packet: [UInt8], from remote: JamEndpoint, at elapsed: TimeInterval) -> [[UInt8]] {
        guard acceptTime(elapsed) else { return [] }
        if expired(at: elapsed) { return finish() }
        guard started, remote == server, JamWire.hasHeader(packet) else { return [] }
        if packet[5] == JamWire.Kind.addressCheck.rawValue {
            let ordinary = packet[4] == JamWire.version && packet.count == JamWire.headerSize + Self.addressCookieBytes
            let grouped = packet[4] == JamWire.groupVersion && packet.count == JamWire.groupHeaderSize + Self.addressCookieBytes
                && packet[JamWire.headerSize..<JamWire.groupHeaderSize].elementsEqual(id)
            guard ordinary || grouped else { return [] }
            answeredAt = answeredAt ?? elapsed
            return [packet]
        }
        guard packet[4] == JamWire.groupVersion, packet.count >= JamWire.groupHeaderSize else { return [] }
        let sender = packet[JamWire.headerSize..<JamWire.groupHeaderSize]
        if packet[5] == JamWire.Kind.serverPing.rawValue {
            guard packet.count == JamWire.groupHeaderSize + 8, sender.elementsEqual(id) else { return [] }
            let stamp = packet.readLE(Int64.self, at: JamWire.groupHeaderSize)
            guard let index = pendingPings.firstIndex(of: stamp) else { return [] }
            let age = elapsed * 1_000_000 - Double(stamp)
            guard age >= 0, age <= Self.limit * 1_000_000 else { return [] }
            pendingPings.remove(at: index)
            answeredAt = answeredAt ?? elapsed
            pingedBackAt = pingedBackAt ?? elapsed
            roundTripMs = roundTripMs ?? age / 1000
            return []
        }
        // Roster/full/status are sent by the server, never by a group member.
        guard sender.allSatisfy({ $0 == 0 }) else { return [] }
        let body = Array(packet[JamWire.groupHeaderSize...])
        switch packet[5] {
        case JamWire.Kind.roster.rawValue:
            guard let count = body.first, Int(count) <= RelayGroupClient.maxTickedIds,
                  body.count >= 1 + Int(count) * RelayGroupClient.rosterEntryBytesWithoutFlags else { return [] }
            answeredAt = answeredAt ?? elapsed
        case JamWire.Kind.full.rawValue:
            answeredAt = answeredAt ?? elapsed
            return finish(full: true)
        case JamWire.Kind.serverInfo.rawValue:
            guard let info = RelayGroupClient.readServerInfo(body, receivedAt: elapsed) else { return [] }
            answeredAt = answeredAt ?? elapsed
            return finish(version: info.version)
        default: break
        }
        return []
    }

    public func cancel() -> [[UInt8]] {
        guard result == nil else { return [] }
        return finish(cancelled: true)
    }

    private func acceptTime(_ elapsed: TimeInterval) -> Bool {
        guard result == nil, elapsed.isFinite, elapsed >= lastElapsed else { return false }
        lastElapsed = elapsed
        return true
    }

    private func expired(at elapsed: TimeInterval) -> Bool {
        if elapsed >= Self.limit { return true }
        if let pingedBackAt { return elapsed - pingedBackAt >= Self.statusWait }
        return answeredAt.map { elapsed - $0 >= Self.olderAfter } ?? false
    }

    private func header(_ kind: JamWire.Kind) -> [UInt8] { JamWire.header(kind.rawValue, version: JamWire.groupVersion) + id }

    private func finish(version: String? = nil, full: Bool = false, cancelled: Bool = false) -> [[UInt8]] {
        result = Result(answered: answeredAt != nil, version: version, roundTripMs: roundTripMs, full: full, cancelled: cancelled)
        pendingPings.removeAll()
        return started ? [[UInt8]](repeating: header(.bye), count: Self.goodbyeCopies) : []
    }
}
