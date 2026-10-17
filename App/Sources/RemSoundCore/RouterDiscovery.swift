import Darwin
import Foundation
import RemSoundRuntime

final class RouterDiscovery {
    enum Mode { case unicast, multicast }
    enum Outcome: Equatable { case found(URL), refused, unavailable, timedOut, cancelled, failure(String) }
    static let maximumDuration: TimeInterval = 8
    private static let responseWindow: TimeInterval = 1
    private static let retryDelay: TimeInterval = 0.5
    private static let maximumReceivesPerTick = 16
    private static let maximumReceivedPackets = 64
    private static let maximumReceivedBytes = 256 * 1024
    private static let discoveryPort: UInt16 = 1900
    private static let multicastAddress = "239.255.255.250"
    private let timeout: TimeInterval, requestedTimeout: TimeInterval, mode: Mode, began: TimeInterval
    private let permitted: () -> Bool, clock: () -> TimeInterval, readRoute: () -> RouterGatewayRoute?
    private let makeTransport: (RouterGatewayRoute, Mode) throws -> RouterUDPTransport
    private let completion: (Outcome) -> Void
    private var transport: RouterUDPTransport?, route: RouterGatewayRoute?, packet: Data?, destination: Endpoint?
    private var finished = false, preparing = false, ticking = false, retirement: Outcome?
    private var sends = 0, receivedPackets = 0, receivedBytes = 0
    init(timeout: TimeInterval = 2, mode: Mode = .unicast, permitted: @escaping () -> Bool, clock: @escaping () -> TimeInterval,
         route: @escaping () -> RouterGatewayRoute?, transport: @escaping (RouterGatewayRoute, Mode) throws -> RouterUDPTransport,
         completion: @escaping (Outcome) -> Void) {
        requestedTimeout = timeout; self.timeout = min(Self.maximumDuration, timeout); self.mode = mode
        self.permitted = permitted; self.clock = clock; readRoute = route; makeTransport = transport
        self.completion = completion; began = clock()
    }
    convenience init(configuration: RuntimeConfiguration, enabled: @escaping () -> Bool, route: RouterGatewayRoute,
                     timeout: TimeInterval = 2, mode: Mode = .unicast, completion: @escaping (Outcome) -> Void) {
        self.init(timeout: timeout, mode: mode, permitted: { !configuration.isIsolated && enabled() },
            clock: { ProcessInfo.processInfo.systemUptime }, route: { route },
            transport: { try NativeRouterDiscoveryTransport(sourceAddress: $0.sourceAddress, mode: $1) }, completion: completion)
    }
    // Tick, cancellation and injected calls share the backend's serial executor.
    // A dedicated ephemeral socket scopes discovery to this visit; SSDP has no nonce
    // or authentication, so a matched response is only a candidate description URL.
    func tick() {
        guard !finished, !preparing, !ticking else { return }
        ticking = true
        defer {
            ticking = false
            if !finished, let retirement { finish(retirement) }
        }
        if let reason = terminal() { finish(reason); return }
        if transport == nil { prepare() }
        guard !finished else { return }
        if let reason = terminal() { finish(reason); return }
        if sends > 0 { receive() }
        guard !finished else { return }
        if let reason = terminal() { finish(reason); return }
        let elapsed = clock() - began
        guard sends == 0 || (sends == 1 && elapsed >= Self.retryDelay && elapsed + Self.responseWindow <= timeout),
              let packet, let destination else { return }
        guard transport?.send(packet, to: destination) == true else { finish(.failure("Could not send router discovery.")); return }
        sends += 1
    }
    func cancel() {
        guard !finished else { return }; retirement = .cancelled
        // A reentrant factory/send/receive is still in progress. Its exact resource
        // must quiesce before the completion permits a replacement visit.
        if preparing || ticking { return }
        finish(.cancelled)
    }
    private func terminal() -> Outcome? {
        if let retirement { return retirement }
        guard permitted() else { return transport == nil ? .refused : .cancelled }
        guard requestedTimeout.isFinite, requestedTimeout >= Self.responseWindow else { return .failure("Invalid router discovery duration.") }
        let now = clock()
        guard began.isFinite, now.isFinite, now >= began else { return .failure("Invalid router discovery clock.") }
        return now - began >= timeout ? .timedOut : nil
    }
    private func prepare() {
        preparing = true; defer { preparing = false }
        guard let selected = readRoute(), selected.isValid else { finish(retirement ?? .unavailable); return }
        if let reason = terminal() { finish(reason); return }
        let bytes: Data?, target: Endpoint
        switch mode {
        case .unicast:
            bytes = UPnPRouterProtocol.unicastSearch(gatewayAddress: selected.gateway.address)
            target = Endpoint(selected.gateway.address, Self.discoveryPort)
        case .multicast:
            bytes = UPnPRouterProtocol.search(mx: 1)
            target = Endpoint(Self.multicastAddress, Self.discoveryPort)
        }
        guard let bytes else { finish(.unavailable); return }
        do {
            let created = try makeTransport(selected, mode)
            guard !finished else { created.close(); return }
            transport = created
            if let reason = terminal() { finish(reason); return }
            guard created.localAddress == selected.sourceAddress else { finish(.failure("Router discovery socket did not bind the selected source.")); return }
            route = selected; packet = bytes; destination = target
        } catch { finish(retirement ?? .failure(error.localizedDescription)) }
    }
    private func receive() {
        guard let route else { return }
        for _ in 0..<Self.maximumReceivesPerTick {
            guard let (data, from) = transport?.receive() else { break }
            guard !finished else { return }
            if let reason = terminal() { finish(reason); return }
            receivedPackets += 1
            guard data.count <= Self.maximumReceivedBytes - receivedBytes else { finish(.failure("Router discovery byte budget exhausted.")); return }
            receivedBytes += data.count
            if data.count <= UPnPRouterProtocol.maximumSSDPBytes,
               let location = UPnPRouterProtocol.discovery(data, from: from, gatewayAddress: route.gateway.address, searchTarget: UPnPRouterProtocol.igd1) {
                finish(.found(location)); return
            }
            if receivedPackets >= Self.maximumReceivedPackets { finish(.failure("Router discovery packet budget exhausted.")); return }
        }
    }
    private func finish(_ result: Outcome) {
        guard !finished else { return }; finished = true
        let previous = transport; transport = nil; previous?.close(); completion(result)
    }
    deinit { cancel() }
}

final class NativeRouterDiscoveryTransport: RouterUDPTransport {
    private static let multicastTTL: UInt8 = 2
    private var udp: UDP?
    private let multicast: Bool
    var localAddress: String? { udp?.boundAddress }
    var boundPort: UInt16 { udp?.boundPort ?? 0 }
    // Read-only native option diagnostics keep the raw descriptor inside Core.
    var multicastSettings: (sourceAddress: String, ttl: Int)? {
        guard multicast, let udp else { return nil }
        var source = in_addr(), ttl: UInt8 = 0
        var sourceSize = socklen_t(MemoryLayout<in_addr>.size), ttlSize = socklen_t(MemoryLayout<UInt8>.size)
        guard getsockopt(udp.fd, IPPROTO_IP, IP_MULTICAST_IF, &source, &sourceSize) == 0,
              getsockopt(udp.fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, &ttlSize) == 0 else { return nil }
        var chars = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &source, &chars, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return (String(cString: chars), Int(ttl))
    }
    init(sourceAddress: String, mode: RouterDiscovery.Mode) throws {
        let created = try UDP(port: 0, localAddress: sourceAddress)
        switch mode {
        case .unicast: multicast = false
        case .multicast:
            multicast = true
            var address = in_addr(), ttl = Self.multicastTTL
            guard inet_pton(AF_INET, sourceAddress, &address) == 1,
                  setsockopt(created.fd, IPPROTO_IP, IP_MULTICAST_IF, &address, socklen_t(MemoryLayout<in_addr>.size)) == 0,
                  setsockopt(created.fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size)) == 0 else {
                throw ProtocolError.invalid("Could not configure selected-interface router discovery.")
            }
        }
        udp = created
    }
    func send(_ data: Data, to: Endpoint) -> Bool { udp?.send(data, to: to) ?? false }
    func receive() -> (Data, Endpoint)? { udp?.receive() }
    func close() { udp = nil }
}
