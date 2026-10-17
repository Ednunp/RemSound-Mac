import Darwin
import Foundation

// One cancellable IPv4 endpoint query, shared by server connections and explicit peer additions.
// Results stay on the caller's owner; native DNS has its own bounded deadline.
final class EndpointAddressResolver {
    typealias Lookup = DirectPeerResolver.Lookup
    private static let maximumHostBytes = 253
    private let owner: DispatchQueue
    private let lookup: Lookup
    private var generation = UUID()
    private var cancellation: (() -> Void)?

    init(owner: DispatchQueue,
        lookup: @escaping Lookup = { DNSAddressLookup.start($0, completion: $1) }) {
        self.owner = owner
        self.lookup = lookup
    }

    func start(_ host: String, port: UInt16, completion: @escaping (Endpoint?) -> Void) {
        stop()
        let current = generation
        let deliver: (String?) -> Void = { [weak self] address in
            self?.owner.async { [weak self] in
                guard let self, self.generation == current else { return }
                self.generation = UUID()
                self.cancellation = nil
                completion(address.flatMap { Self.endpoint($0, port: port) })
            }
        }
        let invalid = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard !host.isEmpty, host.utf8.count <= Self.maximumHostBytes, port != 0,
            !host.unicodeScalars.contains(where: invalid.contains) else {
            deliver(nil)
            return
        }
        if Self.endpoint(host, port: port) != nil {
            deliver(host)
            return
        }
        cancellation = lookup(host, deliver)
    }

    func stop() {
        generation = UUID()
        cancellation?()
        cancellation = nil
    }

    private static func endpoint(_ address: String, port: UInt16) -> Endpoint? {
        var numeric = in_addr()
        guard inet_pton(AF_INET, address, &numeric) == 1 else { return nil }
        return Endpoint(address, port)
    }

    deinit { cancellation?() }
}

struct PeerAddressEntry: Equatable {
    static let maximumHostBytes = 253
    static let maximumEntryBytes = maximumHostBytes + 1 + String(UInt16.max).utf8.count
    let text: String
    let host: String
    let port: UInt16

    static func parse(_ raw: String, defaultPort: UInt16) -> PeerAddressEntry? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = text.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 1 || pieces.count == 2 else { return nil }
        let host = String(pieces[0])
        let invalid = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard !host.isEmpty, host.utf8.count <= maximumHostBytes,
              !host.unicodeScalars.contains(where: invalid.contains),
              !host.contains("/"), !host.contains("\\"), !host.contains("["), !host.contains("]") else { return nil }
        let port: UInt16
        if pieces.count == 2 {
            guard !pieces[1].isEmpty, pieces[1].allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = UInt16(pieces[1]), value != 0 else { return nil }
            port = value
        } else {
            guard defaultPort != 0 else { return nil }
            port = defaultPort
        }
        return .init(text: text, host: host, port: port)
    }
}
