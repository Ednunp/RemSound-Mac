import Darwin
import Foundation
import dnssd

// DNS-SD provides an actual cancellable query. A timed-out libc getaddrinfo
// worker would keep running and accumulate during repeated reconnects.
final class DNSAddressLookup {
    static let timeout: TimeInterval = 5
    private static let queue = DispatchQueue(label: "RemSound peer DNS", qos: .utility)
    private var service: DNSServiceRef?
    private var timer: DispatchSourceTimer?
    private var completion: ((String?) -> Void)?
    private var keepAlive: DNSAddressLookup?

    static func start(_ host: String, timeout: TimeInterval = DNSAddressLookup.timeout,
        completion: @escaping (String?) -> Void) -> () -> Void {
        let lookup = DNSAddressLookup()
        queue.async {
            lookup.keepAlive = lookup
            lookup.completion = completion
            lookup.begin(host, timeout: timeout)
        }
        return { queue.async { lookup.finish(nil, report: false) } }
    }

    private func begin(_ host: String, timeout: TimeInterval) {
        let callback: DNSServiceGetAddrInfoReply = { _, flags, _, error, _, address, _, context in
            guard let context else { return }
            let lookup = Unmanaged<DNSAddressLookup>.fromOpaque(context).takeUnretainedValue()
            guard error == kDNSServiceErr_NoError, let address else {
                lookup.finish(nil)
                return
            }
            guard flags & UInt32(kDNSServiceFlagsAdd) != 0,
                address.pointee.sa_family == sa_family_t(AF_INET) else { return }
            var ip = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            var chars = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &ip, &chars, socklen_t(INET_ADDRSTRLEN)) != nil else { return }
            lookup.finish(String(cString: chars))
        }
        let result = DNSServiceGetAddrInfo(&service, 0, 0, UInt32(kDNSServiceProtocol_IPv4), host,
            callback, Unmanaged.passUnretained(self).toOpaque())
        guard result == kDNSServiceErr_NoError, let service,
            DNSServiceSetDispatchQueue(service, Self.queue) == kDNSServiceErr_NoError else {
            finish(nil)
            return
        }
        let deadline = DispatchSource.makeTimerSource(queue: Self.queue)
        deadline.schedule(deadline: .now() + timeout)
        deadline.setEventHandler { [weak self] in self?.finish(nil) }
        timer = deadline
        deadline.resume()
    }

    private func finish(_ address: String?, report: Bool = true) {
        guard keepAlive != nil else { return }
        timer?.cancel()
        timer = nil
        if let service { DNSServiceRefDeallocate(service) }
        service = nil
        let callback = completion
        completion = nil
        if report { callback?(address) }
        keepAlive = nil
    }
}
