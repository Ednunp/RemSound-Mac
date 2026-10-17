// STAND-IN for Apple's Network framework: declarations only, as Swift imports them, for the parts the app uses
// (NWListener, NWConnection, NWEndpoint, NWParameters, NWPathMonitor). Nothing here opens a socket.
import Foundation
import Dispatch

public enum NWError: Error, CustomDebugStringConvertible, Equatable, Sendable {
    case posix(POSIXErrorCode)
    case dns(Int32)
    case tls(Int32)
    public var debugDescription: String { "" }
}

public enum NWEndpoint: Hashable, CustomDebugStringConvertible, Sendable {
    case hostPort(host: NWEndpoint.Host, port: NWEndpoint.Port)
    case service(name: String, type: String, domain: String, interface: NWInterface?)
    case unix(path: String)
    case url(URL)
    public var debugDescription: String { "" }
    public var interface: NWInterface? { nil }

    public enum Host: Hashable, CustomDebugStringConvertible, ExpressibleByStringLiteral, Sendable {
        case name(String, NWInterface?)
        case ipv4(IPv4Address)
        case ipv6(IPv6Address)
        public init(_ string: String) { self = .name(string, nil) }
        public init(stringLiteral value: String) { self = .name(value, nil) }
        public var debugDescription: String { "" }
        public var interface: NWInterface? { nil }
    }

    public struct Port: Hashable, CustomDebugStringConvertible, ExpressibleByIntegerLiteral, RawRepresentable, Sendable {
        public let rawValue: UInt16
        public init?(rawValue: UInt16) { self.rawValue = rawValue }
        public init?(_ string: String) { guard let v = UInt16(string) else { return nil }; rawValue = v }
        public init(integerLiteral value: UInt16) { rawValue = value }
        public static let any: Port = 0
        public var debugDescription: String { "" }
    }
}

public protocol IPAddress: Sendable {
    init?(_ rawValue: Data, _ interface: NWInterface?)
    var rawValue: Data { get }
    var interface: NWInterface? { get }
    var isLoopback: Bool { get }
    var isLinkLocal: Bool { get }
    var isMulticast: Bool { get }
}

public struct IPv4Address: IPAddress, Hashable, CustomDebugStringConvertible {
    public init?(_ rawValue: Data, _ interface: NWInterface? = nil) { self.rawValue = rawValue; self.interface = interface }
    public init?(_ string: String) { rawValue = Data(); interface = nil }
    public let rawValue: Data
    public let interface: NWInterface?
    public var isLoopback: Bool { false }
    public var isLinkLocal: Bool { false }
    public var isMulticast: Bool { false }
    public static let any = IPv4Address(Data([0, 0, 0, 0]))!
    public static let loopback = IPv4Address(Data([127, 0, 0, 1]))!
    public static let broadcast = IPv4Address(Data([255, 255, 255, 255]))!
    public var debugDescription: String { "" }
}

public struct IPv6Address: IPAddress, Hashable, CustomDebugStringConvertible {
    public init?(_ rawValue: Data, _ interface: NWInterface? = nil) { self.rawValue = rawValue; self.interface = interface }
    public init?(_ string: String) { rawValue = Data(); interface = nil }
    public let rawValue: Data
    public let interface: NWInterface?
    public var isLoopback: Bool { false }
    public var isLinkLocal: Bool { false }
    public var isMulticast: Bool { false }
    public var isIPv4Mapped: Bool { false }
    public var asIPv4: IPv4Address? { nil }
    public static let any = IPv6Address(Data(count: 16))!
    public static let loopback = IPv6Address(Data(count: 16))!
    public var debugDescription: String { "" }
}

public struct NWInterface: Hashable, CustomDebugStringConvertible, Sendable {
    public enum InterfaceType: Hashable, Sendable { case other, wifi, cellular, wiredEthernet, loopback }
    public let type: InterfaceType
    public let name: String
    public let index: Int
    public var debugDescription: String { "" }
}

public final class NWParameters: CustomDebugStringConvertible, @unchecked Sendable {
    public init() {}
    public static var tcp: NWParameters { NWParameters() }
    public static var udp: NWParameters { NWParameters() }
    public static var tls: NWParameters { NWParameters() }
    public static var dtls: NWParameters { NWParameters() }
    public var requiredInterfaceType: NWInterface.InterfaceType = .other
    public var prohibitedInterfaceTypes: [NWInterface.InterfaceType]? = nil
    public var requiredLocalEndpoint: NWEndpoint? = nil
    public var allowLocalEndpointReuse: Bool = false
    public var acceptLocalOnly: Bool = false
    public var includePeerToPeer: Bool = false
    public var allowFastOpen: Bool = false
    public var serviceClass: ServiceClass = .bestEffort
    public var multipathServiceType: MultipathServiceType = .disabled
    public var preferNoProxies: Bool = false
    public var debugDescription: String { "" }
    public enum ServiceClass: Sendable { case bestEffort, background, interactiveVideo, interactiveVoice, responsiveData, signaling }
    public enum MultipathServiceType: Sendable { case disabled, handover, interactive, aggregate }
}

public final class NWListener: CustomDebugStringConvertible, @unchecked Sendable {
    public enum State: Equatable, Sendable { case setup, waiting(NWError), ready, failed(NWError), cancelled }
    public init(using parameters: NWParameters, on port: NWEndpoint.Port) throws {}
    public init(using parameters: NWParameters) throws {}
    public var stateUpdateHandler: (@Sendable (NWListener.State) -> Void)?
    public var newConnectionHandler: (@Sendable (NWConnection) -> Void)?
    public var newConnectionLimit: Int = 0
    public var state: NWListener.State { .setup }
    public var port: NWEndpoint.Port? { nil }
    public var parameters: NWParameters { NWParameters() }
    public var queue: DispatchQueue? { nil }
    public func start(queue: DispatchQueue) {}
    public func cancel() {}
    public var debugDescription: String { "" }
}

public final class NWConnection: CustomDebugStringConvertible, @unchecked Sendable {
    public enum State: Equatable, Sendable { case setup, waiting(NWError), preparing, ready, failed(NWError), cancelled }
    public init(host: NWEndpoint.Host, port: NWEndpoint.Port, using: NWParameters) { endpoint = .hostPort(host: host, port: port) }
    public init(to endpoint: NWEndpoint, using: NWParameters) { self.endpoint = endpoint }
    public let endpoint: NWEndpoint
    public var state: NWConnection.State { .setup }
    public var parameters: NWParameters { NWParameters() }
    public var currentPath: NWPath? { nil }
    public var queue: DispatchQueue? { nil }
    public var stateUpdateHandler: (@Sendable (NWConnection.State) -> Void)?
    public var viabilityUpdateHandler: (@Sendable (Bool) -> Void)?
    public var betterPathUpdateHandler: (@Sendable (Bool) -> Void)?
    public var pathUpdateHandler: (@Sendable (NWPath) -> Void)?
    public func start(queue: DispatchQueue) {}
    public func restart() {}
    public func cancel() {}
    public func forceCancel() {}
    public func cancelCurrentEndpoint() {}
    public var maximumDatagramSize: Int { 0 }

    public final class ContentContext: @unchecked Sendable {
        public init(identifier: String, expiration: UInt64 = 0, priority: Double = 0.5, isFinal: Bool = false, antecedent: ContentContext? = nil) {}
        public static let defaultMessage = ContentContext(identifier: "")
        public static let finalMessage = ContentContext(identifier: "", isFinal: true)
        public static let defaultStream = ContentContext(identifier: "")
        public var isFinal: Bool { false }
        public let identifier: String = ""
    }

    public enum SendCompletion: Sendable {
        case contentProcessed(@Sendable (NWError?) -> Void)
        case idempotent
    }

    public func send(content: Data?, contentContext: ContentContext = .defaultMessage, isComplete: Bool = true, completion: SendCompletion) {}
    public func receive(minimumIncompleteLength: Int, maximumLength: Int,
                        completion: @escaping @Sendable (_ content: Data?, _ contentContext: ContentContext?, _ isComplete: Bool, _ error: NWError?) -> Void) {}
    public func receiveMessage(completion: @escaping @Sendable (_ content: Data?, _ contentContext: ContentContext?, _ isComplete: Bool, _ error: NWError?) -> Void) {}
    public var debugDescription: String { "" }
}

public struct NWPath: Equatable, CustomDebugStringConvertible, Sendable {
    public enum Status: Equatable, Sendable { case satisfied, unsatisfied, requiresConnection }
    public enum UnsatisfiedReason: Equatable, Sendable { case notAvailable, cellularDenied, wifiDenied, localNetworkDenied, vpnInactive }
    public var status: Status { .unsatisfied }
    public var unsatisfiedReason: UnsatisfiedReason { .notAvailable }
    public var availableInterfaces: [NWInterface] { [] }
    public var gateways: [NWEndpoint] { [] }
    public var localEndpoint: NWEndpoint? { nil }
    public var remoteEndpoint: NWEndpoint? { nil }
    public var isExpensive: Bool { false }
    public var isConstrained: Bool { false }
    public var supportsIPv4: Bool { false }
    public var supportsIPv6: Bool { false }
    public var supportsDNS: Bool { false }
    public func usesInterfaceType(_ type: NWInterface.InterfaceType) -> Bool { false }
    public var debugDescription: String { "" }
}

public final class NWPathMonitor: @unchecked Sendable {
    public init() {}
    public init(requiredInterfaceType: NWInterface.InterfaceType) {}
    public init(prohibitedInterfaceTypes: [NWInterface.InterfaceType]) {}
    public var currentPath: NWPath { NWPath() }
    public var pathUpdateHandler: (@Sendable (NWPath) -> Void)?
    public var queue: DispatchQueue? { nil }
    public func start(queue: DispatchQueue) {}
    public func cancel() {}
}
