import Foundation
import RemSoundRuntime
import SystemConfiguration

struct RouterGatewayRoute: Equatable {
    let gateway: Endpoint, sourceAddress: String, interface: String
    static func read() -> RouterGatewayRoute? {
        guard let state = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let address = state["Router"] as? String, RouterMappingPackets.ipv4(address) != nil,
              let interface = state["PrimaryInterface"] as? String else { return nil }
        let gateway = Endpoint(address, RouterMappingPackets.gatewayPort)
        guard let selected = NetworkRoute.read(to: gateway), selected.interface == interface,
              RouterMappingPackets.ipv4(selected.sourceAddress) != nil else { return nil }
        return .init(gateway: gateway, sourceAddress: selected.sourceAddress, interface: interface)
    }
    var isValid: Bool {
        gateway.port == RouterMappingPackets.gatewayPort && RouterMappingPackets.ipv4(gateway.address) != nil
            && RouterMappingPackets.ipv4(sourceAddress) != nil && !interface.isEmpty
    }
}
protocol RouterUDPTransport: AnyObject {
    var localAddress: String? { get }
    func send(_ packet: Data, to: Endpoint) -> Bool
    func receive() -> (Data, Endpoint)?
    func close()
}
final class NativeRouterUDPTransport: RouterUDPTransport {
    private var udp: UDP?
    var localAddress: String? { udp?.boundAddress }
    var boundPort: UInt16 { udp?.boundPort ?? 0 }
    init(sourceAddress: String) throws { udp = try UDP(port: 0, localAddress: sourceAddress) }
    func send(_ packet: Data, to: Endpoint) -> Bool { udp?.send(packet, to: to) ?? false }
    func receive() -> (Data, Endpoint)? { udp?.receive() }
    func close() { udp = nil }
}
final class RouterUDPExchange {
    enum Request {
        case pcpAnnounce, natAddress
        case natMap(internalPort: UInt16, externalPort: UInt16, lifetime: UInt32)
        case pcpMap(nonce: Data, internalPort: UInt16, externalPort: UInt16, lifetime: UInt32, externalAddress: String?)
        var isPcp: Bool { switch self { case .pcpAnnounce, .pcpMap: return true; default: return false } }
        var mutates: Bool { switch self { case .natMap, .pcpMap: return true; default: return false } }
        var isValid: Bool {
            switch self {
            case .natAddress, .pcpAnnounce: return true
            case let .natMap(port, _, _): return port > 0
            case let .pcpMap(nonce, port, _, _, address):
                return port > 0 && nonce.count == RouterMappingPackets.pcpNonceSize && (address.map { RouterMappingPackets.ipv4($0) != nil } ?? true)
            }
        }
        func packet(_ route: RouterGatewayRoute) -> Data? {
            switch self {
            case .natAddress: return RouterMappingPackets.natAddressRequest()
            case .pcpAnnounce: return RouterMappingPackets.pcpAnnounceRequest(clientAddress: route.sourceAddress)
            case let .natMap(port, external, lifetime): return RouterMappingPackets.natMapRequest(internalPort: port, suggestedPort: external, lifetime: lifetime)
            case let .pcpMap(nonce, port, external, lifetime, address):
                return RouterMappingPackets.pcpMapRequest(clientAddress: route.sourceAddress, nonce: nonce, internalPort: port, suggestedPort: external, lifetime: lifetime, suggestedAddress: address)
            }
        }
        func reply(_ data: Data, from: Endpoint, route: RouterGatewayRoute) -> RouterMappingReply? {
            switch self {
            case .natAddress: return RouterMappingPackets.natAddressReply(data, from: from, gateway: route.gateway)
            case let .natMap(port, _, lifetime): return RouterMappingPackets.natMapReply(data, from: from, gateway: route.gateway, internalPort: port, deleting: lifetime == 0)
            case .pcpAnnounce:
                if let value = RouterMappingPackets.pcpAnnounceReply(data, from: from, gateway: route.gateway) { return value }
                if let value = RouterMappingPackets.natAddressReply(data, from: from, gateway: route.gateway), value.resultCode == 1 { return value }
                return nil
            case let .pcpMap(nonce, port, _, lifetime, _):
                if let value = RouterMappingPackets.pcpMapReply(data, from: from, gateway: route.gateway, nonce: nonce, internalPort: port, deleting: lifetime == 0) { return value }
                if data.count == 8, let value = RouterMappingPackets.natMapReply(data, from: from, gateway: route.gateway, internalPort: port), value.resultCode == 1 { return value }
                return nil
            }
        }
    }
    enum Outcome: Equatable {
        case refused, unavailable
        case response(RouterMappingReply, RouterGatewayRoute)
        case lateResponse(RouterMappingReply, RouterGatewayRoute)
        case timedOut(mutationMayHaveOccurred: Bool)
        case cancelled(mutationMayHaveOccurred: Bool)
        case failed(String, mutationMayHaveOccurred: Bool)
    }
    static let deadline: TimeInterval = 8
    static let maximumReceivesPerTick = 16
    private static let natInitialRetry: TimeInterval = 0.25
    private static let pcpInitialRetry: TimeInterval = 3
    private let request: Request, permitted: () -> Bool, clock: () -> TimeInterval
    private let readRoute: () -> RouterGatewayRoute?, makeTransport: (RouterGatewayRoute) throws -> RouterUDPTransport
    private let jitter: () -> Double, completion: (Outcome) -> Void
    private let began: TimeInterval
    private var route: RouterGatewayRoute?, transport: RouterUDPTransport?, packet: Data?
    private var nextSend: TimeInterval = 0, retry: TimeInterval = 0, sent = false, finished = false
    init(request: Request, permitted: @escaping () -> Bool, clock: @escaping () -> TimeInterval,
         route: @escaping () -> RouterGatewayRoute?, transport: @escaping (RouterGatewayRoute) throws -> RouterUDPTransport,
         jitter: @escaping () -> Double = { Double.random(in: -0.1...0.1) }, completion: @escaping (Outcome) -> Void) {
        self.request = request; self.permitted = permitted; self.clock = clock; readRoute = route
        makeTransport = transport; self.jitter = jitter; self.completion = completion; began = clock()
        retry = request.isPcp ? Self.pcpInitialRetry : Self.natInitialRetry
    }
    convenience init(request: Request, configuration: RuntimeConfiguration, enabled: @escaping () -> Bool,
                     completion: @escaping (Outcome) -> Void) {
        self.init(request: request, permitted: { !configuration.isIsolated && enabled() }, clock: { ProcessInfo.processInfo.systemUptime },
                  route: RouterGatewayRoute.read, transport: { try NativeRouterUDPTransport(sourceAddress: $0.sourceAddress) }, completion: completion)
    }
    func tick() {
        guard !finished else { return }
        guard permitted() else {
            if transport != nil { cancel() } else { finish(.refused) }
            return
        }
        guard request.isValid else { finish(.failed("Invalid router mapping request.", mutationMayHaveOccurred: false)); return }
        let elapsed = clock() - began
        if elapsed >= Self.deadline { retire(timeout: true); return }
        if transport == nil {
            guard let selected = readRoute(), selected.isValid, let data = request.packet(selected) else { finish(.unavailable); return }
            guard !finished else { return }
            guard permitted() else { finish(.refused); return }
            if clock() - began >= Self.deadline { retire(timeout: true); return }
            route = selected; packet = data
            do {
                let created = try makeTransport(selected)
                guard !finished else { created.close(); return }
                transport = created
                guard permitted() else { cancel(); return }
                if clock() - began >= Self.deadline { retire(timeout: true); return }
                guard created.localAddress == selected.sourceAddress else {
                    finish(.failed("The router socket did not bind the selected local address.", mutationMayHaveOccurred: false)); return
                }
            } catch { finish(.failed(error.localizedDescription, mutationMayHaveOccurred: false)); return }
        }
        if let reply = receive(), let route {
            finish(!permitted() || clock() - began >= Self.deadline ? .lateResponse(reply, route) : .response(reply, route)); return
        }
        guard !finished, permitted() else { cancel(); return }
        guard elapsed >= nextSend, let route, let packet else { return }
        guard transport?.send(packet, to: route.gateway) == true else {
            finish(.failed("Could not send the router request.", mutationMayHaveOccurred: sent && request.mutates)); return
        }
        sent = true
        let factor = request.isPcp ? jitter() : 0
        let bounded = factor.isFinite ? min(0.1, max(-0.1, factor)) : 0
        nextSend = elapsed + retry * (1 + bounded)
        retry *= 2
    }
    func cancel() { guard !finished else { return }; retire(timeout: false) }
    private func receive() -> RouterMappingReply? {
        guard sent, let route else { return nil }
        for _ in 0..<Self.maximumReceivesPerTick {
            guard let (data, from) = transport?.receive() else { break }
            if let reply = request.reply(data, from: from, route: route) { return reply }
        }
        return nil
    }
    private func retire(timeout: Bool) {
        // A buffered successful mutation still belongs to this visit and must reach its
        // lease owner for cleanup, even after the caller has cancelled or timed out.
        if let reply = receive(), let route { finish(.lateResponse(reply, route)); return }
        let uncertain = sent && request.mutates
        finish(timeout ? .timedOut(mutationMayHaveOccurred: uncertain) : .cancelled(mutationMayHaveOccurred: uncertain))
    }
    private func finish(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true
        let previous = transport; transport = nil; previous?.close()
        completion(outcome)
    }
    deinit { cancel() }
}
