import Foundation
import RemSoundJam

protocol ServerProbeTransport: AnyObject {
    func send(_ packet: Data, to: Endpoint)
    func receive() -> (Data, Endpoint)?
    func close()
}

final class UDPServerProbeTransport: ServerProbeTransport {
    private var udp: UDP?
    init(loopback: Bool = false) throws { udp = try UDP(port: 0, loopback: loopback) }
    func send(_ packet: Data, to: Endpoint) { udp?.send(packet, to: to) }
    func receive() -> (Data, Endpoint)? { udp?.receive() }
    func close() { udp = nil }
}

public struct ServerVersionWarning {
    public let requestID: UUID
    public let server: String
    public let version: String?
    public let latestReleased: String?
    public let beforeConnecting: Bool
    public let isCurrent: () -> Bool
    public init(requestID: UUID, server: String, version: String?, latestReleased: String?,
                beforeConnecting: Bool, isCurrent: @escaping () -> Bool) {
        self.requestID = requestID; self.server = server; self.version = version
        self.latestReleased = latestReleased; self.beforeConnecting = beforeConnecting; self.isCurrent = isCurrent
    }
}

/// Owner-queue operation, ticked by Session's existing worker. No timer or audio socket is added.
final class ServerVersionOperation {
    private static let maximumReceivesPerTick = 16
    private let endpoint: Endpoint
    private let permitted: Bool
    private let clock: () -> TimeInterval
    private let factory: () throws -> ServerProbeTransport
    private let completion: (ServerVersionProbe.Result) -> Void
    private let began: TimeInterval
    private let probe: ServerVersionProbe
    private var transport: ServerProbeTransport?
    private var finished = false

    init(endpoint: Endpoint, permitted: Bool, clock: @escaping () -> TimeInterval,
         factory: @escaping () throws -> ServerProbeTransport = { try UDPServerProbeTransport() },
         completion: @escaping (ServerVersionProbe.Result) -> Void) {
        self.endpoint = endpoint; self.permitted = permitted; self.clock = clock
        self.factory = factory; self.completion = completion; began = clock()
        probe = ServerVersionProbe(server: JamEndpoint(endpoint), clientID: UUID(),
            groupTag: (0..<JamWire.fingerprintSize).map { _ in UInt8.random(in: .min ... .max) })
    }

    func tick() {
        guard !finished else { return }
        guard permitted else { finish(.init(answered: false, version: nil, roundTripMs: nil, full: false)); return }
        if transport == nil {
            do { transport = try factory() }
            catch { finish(.init(answered: false, version: nil, roundTripMs: nil, full: false)); return }
        }
        let elapsed = clock() - began
        send(probe.tick(at: elapsed))
        if let result = probe.result { finish(result); return }
        for _ in 0..<Self.maximumReceivesPerTick {
            guard let (data, from) = transport?.receive() else { break }
            send(probe.receive([UInt8](data), from: JamEndpoint(from), at: elapsed))
            if let result = probe.result { finish(result); return }
        }
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        send(probe.cancel())
        transport?.close(); transport = nil
    }

    private func send(_ packets: [[UInt8]]) { for packet in packets { transport?.send(Data(packet), to: endpoint) } }
    private func finish(_ result: ServerVersionProbe.Result) {
        finished = true
        transport?.close(); transport = nil
        completion(result)
    }
    deinit { cancel() }
}

/// The main-thread question may outlive its connection. A reply never reopens a retired visit.
final class ServerVersionAnswerToken {
    private let lock = NSLock()
    private var current = true
    var isCurrent: Bool { lock.lock(); defer { lock.unlock() }; return current }
    func retire() { lock.lock(); current = false; lock.unlock() }
}

final class ServerVersionConnectionRequest {
    static let releaseWaitAfterProbe: TimeInterval = 1.5
    static let releaseWaitForLateCheck: TimeInterval = 10
    static let pingingStatusWait: TimeInterval = 20
    let id: UUID
    let entry: String
    let endpoint: Endpoint
    let began: TimeInterval
    var latestReleased: String?
    var releaseDone = false
    var releaseCancellation: (() -> Void)?
    var probe: ServerVersionProbe.Result?
    var probeFinishedAt: TimeInterval?
    var awaitingLate = false
    var deciding = false
    var judged = false
    var answerToken: ServerVersionAnswerToken?
    init(id: UUID, entry: String, endpoint: Endpoint, began: TimeInterval) {
        self.id = id; self.entry = entry; self.endpoint = endpoint; self.began = began
    }
}
