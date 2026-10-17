import Foundation
import RemSoundJam

/// The server release family is Ednunp/RemSound, independent of this app's updater repository.
/// Queue-owned cache and transport; each connection receives an independently cancellable subscription.
final class ServerReleaseLookup {
    typealias Fetch = (@escaping (Data?) -> Void) -> () -> Void
    static let maximumBytes = 2 * 1024 * 1024
    private static let timeout: TimeInterval = 10
    private let queue = DispatchQueue(label: "RemSound server release lookup")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let permitted: () -> Bool
    private let clock: () -> TimeInterval
    private let fetch: Fetch
    private var cache: ServerReleaseCache?
    private var pending: [UUID: Ticket] = [:]
    private var nativeCancellation: (() -> Void)?
    private var generation = UUID()
    private var stopped = false

    private final class Ticket {
        private let lock = NSLock()
        private var current = true
        var isCurrent: Bool { lock.lock(); defer { lock.unlock() }; return current }
        func retire() { lock.lock(); current = false; lock.unlock() }
    }

    init(permitted: @escaping () -> Bool, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         fetch: @escaping Fetch = { ServerReleaseLookup.nativeFetch($0) }) {
        self.permitted = permitted; self.clock = clock; self.fetch = fetch
        queue.setSpecific(key: queueKey, value: 1)
    }

    func latest(_ completion: @escaping (String?) -> Void) -> () -> Void {
        let ticket = Ticket(), id = UUID()
        queue.async { [weak self] in
            guard ticket.isCurrent else { return }
            guard let self, !self.stopped, self.permitted() else { ticket.retire(); completion(nil); return }
            self.pending[id] = ticket
            if self.cache == nil {
                self.cache = ServerReleaseCache(clock: self.clock, fetch: { [weak self] reply in self?.startFetch(reply) })
            }
            self.cache?.latest { [weak self] value in
                guard let self, self.pending[id] === ticket, ticket.isCurrent, !self.stopped else { return }
                self.pending[id] = nil
                ticket.retire()
                completion(value)
            }
        }
        return { [weak self] in
            ticket.retire()
            self?.queue.async { [weak self] in
                guard let self else { return }
                self.pending[id] = nil
                if self.pending.isEmpty, self.nativeCancellation != nil { self.cancelFetch() }
            }
        }
    }

    private func startFetch(_ completion: @escaping (String?) -> Void) {
        let current = UUID(); generation = current
        nativeCancellation = fetch { [weak self] data in
            self?.queue.async { [weak self] in
                guard let self, !self.stopped, self.generation == current else { return }
                self.generation = UUID()
                self.nativeCancellation = nil
                let tag = data.flatMap { $0.count <= Self.maximumBytes ? ServerVersionCheck.newestRelease(in: $0) : nil }
                completion(tag)
            }
        }
    }

    private func cancelFetch() {
        generation = UUID()
        nativeCancellation?(); nativeCancellation = nil
        cache = nil
    }

    func shutdown() {
        let stop = { [self] in
            guard !stopped else { return }
            stopped = true
            pending.values.forEach { $0.retire() }; pending.removeAll()
            cancelFetch()
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil { stop() } else { queue.sync(execute: stop) }
    }

    private final class NativeLifetime {
        let session: URLSession
        private let lock = NSLock()
        private var closed = false
        init(_ session: URLSession) { self.session = session }
        func close() {
            lock.lock()
            guard !closed else { lock.unlock(); return }
            closed = true; lock.unlock()
            session.invalidateAndCancel()
        }
    }

    // A per-session configuration keeps native streaming tests off the network.
    static func nativeFetch(_ completion: @escaping (Data?) -> Void,
                            configuration: URLSessionConfiguration = .ephemeral, requestTimeout: TimeInterval = timeout) -> () -> Void {
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let lifetime = NativeLifetime(URLSession(configuration: configuration))
        let task = Task {
            var result: Data?
            defer { lifetime.close(); completion(result) }
            do {
                var request = URLRequest(url: ServerVersionCheck.releaseListURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)
                request.setValue("RemSound Mac server version check", forHTTPHeaderField: "User-Agent")
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (bytes, response) = try await lifetime.session.bytes(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      http.url?.scheme == "https", http.url?.host == "api.github.com",
                      response.expectedContentLength <= maximumBytes else { return }
                var data = Data()
                for try await byte in bytes {
                    guard data.count < maximumBytes else { return }
                    data.append(byte)
                }
                try Task.checkCancellation()
                result = data
            } catch { result = nil }
        }
        return { task.cancel(); lifetime.close() }
    }
    deinit { nativeCancellation?() }
}
