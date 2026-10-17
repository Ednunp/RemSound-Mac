#if canImport(Darwin)
import Darwin
import Foundation

public enum LocalControlError: Error, LocalizedError {
    case unsafePath, pathTooLong, addressInUse, unavailable, unauthorizedPeer, timedOut, invalidMessage
    public var errorDescription: String? {
        switch self {
        case .unsafePath: return "The local control path is not private to this user."
        case .pathTooLong: return "The local control path is too long; choose a shorter configuration folder."
        case .addressInUse: return "The local control path is already in use."
        case .unavailable: return "No isolated RemSound control channel answered."
        case .unauthorizedPeer: return "The local control peer does not belong to this user."
        case .timedOut: return "The local control operation timed out."
        case .invalidMessage: return "The local control message is invalid or too large."
        }
    }
}

enum ControlTransport {
    static let maximumRequestBytes = 16_384
    static let maximumReplyBytes = 65_536
    static let listenerPollMilliseconds: Int32 = 50

    static func validIdentifier(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.count <= 64, (97...122).contains(bytes[0]) else { return false }
        return bytes.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }
    }
    static func valid(_ request: ControlRequest) -> Bool {
        request.version == 1 && validIdentifier(request.action) && request.arguments.count <= 16
            && request.arguments.allSatisfy { validIdentifier($0.key) && $0.value.utf8.count <= 4096 && !$0.value.contains("\0") }
    }
    private static func sensitive(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return ["password", "secret", "credential", "token", "private-key", "shared-key", "derived-key", "keychain"]
            .contains { lowered.contains($0) }
    }
    static func redacted(_ reply: ControlReply, for request: ControlRequest) -> ControlReply {
        let secrets = request.arguments.filter { sensitive($0.key) || sensitive(request.action) }
            .map(\.value).filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        func cleaned(_ text: String) -> String {
            secrets.reduce(text) { $0.replacingOccurrences(of: $1, with: "[redacted]") }
        }
        var state = [String: String]()
        for (key, value) in reply.state {
            if key == "password-present", value == "true" || value == "false" {
                state[key] = value
            } else if !sensitive(key) {
                state[cleaned(key)] = cleaned(value)
            }
        }
        return ControlReply(request: request, status: reply.status, message: cleaned(reply.message), state: state)
    }
    static func peerAllowed(actual: uid_t?, owner: uid_t, real: uid_t, effective: uid_t) -> Bool {
        real == effective && actual == owner && owner == effective
    }
    static func verifyPeer(_ descriptor: Int32) throws {
        var user: uid_t = 0, group: gid_t = 0
        let result = getpeereid(descriptor, &user, &group)
        guard peerAllowed(actual: result == 0 ? user : nil, owner: geteuid(), real: getuid(), effective: geteuid()) else {
            throw LocalControlError.unauthorizedPeer
        }
    }
    static func validateParent(_ url: URL) throws {
        guard url.isFileURL, getuid() == geteuid() else { throw LocalControlError.unsafePath }
        var ancestor = url.deletingLastPathComponent()
        while ancestor.path != "/" {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: ancestor.path),
                attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw LocalControlError.unsafePath }
            ancestor.deleteLastPathComponent()
        }
        let parent = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        guard parent[.type] as? FileAttributeType == .typeDirectory,
            (parent[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
            (parent[.posixPermissions] as? NSNumber)?.intValue == 0o700 else {
            throw LocalControlError.unsafePath
        }
    }
    static func socketIdentity(_ url: URL) throws -> (device: UInt64, inode: UInt64) {
        try validateParent(url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeSocket,
            (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
            (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
            let device = attributes[.systemNumber] as? NSNumber,
            let inode = attributes[.systemFileNumber] as? NSNumber else { throw LocalControlError.unsafePath }
        return (device.uint64Value, inode.uint64Value)
    }
    static func address(_ path: String) throws -> sockaddr_un {
        var value = sockaddr_un()
        value.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard !bytes.contains(0), bytes.count < MemoryLayout.size(ofValue: value.sun_path) else {
            throw LocalControlError.pathTooLong
        }
        withUnsafeMutableBytes(of: &value.sun_path) { target in
            target.initializeMemory(as: UInt8.self, repeating: 0)
            target.copyBytes(from: bytes)
        }
        value.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return value
    }
    static func makeSocket() throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw LocalControlError.unavailable }
        var enabled: Int32 = 1
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
            fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            close(descriptor)
            throw LocalControlError.unavailable
        }
        return descriptor
    }
    static func deadline(_ timeout: TimeInterval) -> UInt64 {
        DispatchTime.now().uptimeNanoseconds + UInt64(max(0.05, min(10, timeout)) * 1_000_000_000)
    }
    static func wait(_ descriptor: Int32, events: Int16, until deadline: UInt64) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw LocalControlError.timedOut }
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let milliseconds = Int32(min(1000, max(1, (deadline - now) / 1_000_000)))
            let result = poll(&item, 1, milliseconds)
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw LocalControlError.unavailable }
            if result == 0 { continue }
            if item.revents & events != 0 { return }
            throw LocalControlError.unavailable
        }
    }
    static func write(_ data: Data, descriptor: Int32, until deadline: UInt64) throws {
        var position = 0
        try data.withUnsafeBytes { bytes in
            while position < bytes.count {
                try wait(descriptor, events: Int16(POLLOUT), until: deadline)
                let count = send(descriptor, bytes.baseAddress!.advanced(by: position), bytes.count - position, 0)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard count > 0 else { throw LocalControlError.unavailable }
                position += count
            }
        }
    }
    static func read(_ count: Int, descriptor: Int32, until deadline: UInt64) throws -> Data {
        var result = Data(count: count), position = 0
        try result.withUnsafeMutableBytes { bytes in
            while position < count {
                try wait(descriptor, events: Int16(POLLIN), until: deadline)
                let received = recv(descriptor, bytes.baseAddress!.advanced(by: position), count - position, 0)
                if received < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard received > 0 else { throw LocalControlError.invalidMessage }
                position += received
            }
        }
        return result
    }
    static func sendFrame(_ data: Data, maximum: Int, descriptor: Int32, until deadline: UInt64) throws {
        guard !data.isEmpty, data.count <= maximum else { throw LocalControlError.invalidMessage }
        var length = UInt32(data.count).bigEndian
        try write(withUnsafeBytes(of: &length) { Data($0) }, descriptor: descriptor, until: deadline)
        try write(data, descriptor: descriptor, until: deadline)
    }
    static func receiveFrame(maximum: Int, descriptor: Int32, until deadline: UInt64) throws -> Data {
        let header = try read(4, descriptor: descriptor, until: deadline)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= maximum else { throw LocalControlError.invalidMessage }
        return try read(Int(length), descriptor: descriptor, until: deadline)
    }
}

/// A queued action must claim this lease on its execution thread before changing app state.
/// Cancellation prevents a late queued action from starting; a running action has an explicitly unknown outcome.
public final class ControlOperation {
    public let request: ControlRequest
    private let deadline: UInt64
    private let lock = NSLock()
    private let completed = DispatchSemaphore(value: 0)
    private let acknowledge: () -> Void
    private var began = false, cancelled = false, acknowledged = false, invalidReply = false
    private var reply: ControlReply?

    init(request: ControlRequest, deadline: UInt64, acknowledge: @escaping () -> Void) {
        self.request = request
        self.deadline = deadline
        self.acknowledge = acknowledge
    }
    public func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !began, !cancelled, !acknowledged, DispatchTime.now().uptimeNanoseconds < deadline else { return false }
        began = true
        return true
    }
    /// Call even when begin returns false, so the single outstanding dispatch slot can be released.
    public func finish(_ result: ControlReply) {
        lock.lock()
        guard !acknowledged else { lock.unlock(); return }
        acknowledged = true
        invalidReply = result.id != request.id
        if began, !cancelled, !invalidReply, DispatchTime.now().uptimeNanoseconds < deadline { reply = result }
        lock.unlock()
        acknowledge()
        completed.signal()
    }
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        completed.signal()
    }
    func wait() -> ControlReply? {
        _ = completed.wait(timeout: DispatchTime(uptimeNanoseconds: deadline))
        lock.lock()
        defer { lock.unlock() }
        if invalidReply { return nil }
        if let reply { return reply }
        cancelled = true
        return ControlReply(request: request, status: began ? .waiting : .error,
            message: began ? "The action started; its outcome is not yet known." : "The action was cancelled before it started.")
    }
}

/// One bounded command per connection. This transport never logs requests, values or replies.
public final class LocalControlServer {
    private let url: URL
    private let timeout: TimeInterval
    private let dispatcher: (ControlOperation) -> Void
    private let queue = DispatchQueue(label: "RemSound private control")
    private let delivery = DispatchQueue(label: "RemSound control dispatch")
    private let dispatchSlot = DispatchSemaphore(value: 1)
    private let lock = NSLock()
    private let finished = DispatchGroup()
    private var listener: Int32 = -1
    private var accepted: Int32 = -1
    private var stopping = false
    private var started = false
    private var identity: (device: UInt64, inode: UInt64)?
    private var operation: ControlOperation?

    public init(socketURL: URL, timeout: TimeInterval = 3, dispatcher: @escaping (ControlOperation) -> Void) {
        url = socketURL
        self.timeout = timeout.isFinite ? max(0.05, min(10, timeout)) : 3
        self.dispatcher = dispatcher
    }
    public convenience init(socketURL: URL, timeout: TimeInterval = 3, handler: @escaping (ControlRequest) -> ControlReply) {
        self.init(socketURL: socketURL, timeout: timeout, dispatcher: { operation in
            let reply = operation.begin() ? handler(operation.request)
                : ControlReply(request: operation.request, status: .error, message: "The action was cancelled.")
            operation.finish(reply)
        })
    }
    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { throw LocalControlError.addressInUse }
        guard !stopping else { throw LocalControlError.unavailable }
        try ControlTransport.validateParent(url)
        guard (try? FileManager.default.attributesOfItem(atPath: url.path)) == nil else {
            throw LocalControlError.addressInUse
        }
        var address = try ControlTransport.address(url.path)
        let descriptor = try ControlTransport.makeSocket()
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { close(descriptor); throw LocalControlError.addressInUse }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            identity = try ControlTransport.socketIdentity(url)
            guard listen(descriptor, 4) == 0 else { throw LocalControlError.unavailable }
        } catch {
            close(descriptor)
            removeOwnSocket()
            throw error
        }
        listener = descriptor
        started = true
        finished.enter()
        queue.async { [self] in
            loop(descriptor)
            finished.leave()
        }
    }
    @discardableResult public func stop() -> Bool {
        lock.lock()
        stopping = true
        if listener >= 0 { shutdown(listener, SHUT_RDWR) }
        if accepted >= 0 { shutdown(accepted, SHUT_RDWR) }
        operation?.cancel()
        lock.unlock()
        let ended = finished.wait(timeout: .now() + 11) == .success
        if ended {
            lock.lock()
            removeOwnSocket()
            identity = nil
            lock.unlock()
        }
        return ended
    }
    private func removeOwnSocket() {
        guard let original = identity, let current = try? ControlTransport.socketIdentity(url),
            original.device == current.device, original.inode == current.inode else { return }
        try? FileManager.default.removeItem(at: url)
    }
    private func loop(_ descriptor: Int32) {
        defer {
            lock.lock()
            listener = -1
            close(descriptor)
            lock.unlock()
        }
        while true {
            lock.lock()
            let done = stopping
            lock.unlock()
            if done { return }
            var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&item, 1, ControlTransport.listenerPollMilliseconds)
            if ready <= 0 { continue }
            let connection = accept(descriptor, nil, nil)
            if connection < 0 { continue }
            lock.lock()
            accepted = connection
            let reject = stopping
            lock.unlock()
            if !reject { serve(connection) }
            lock.lock()
            accepted = -1
            close(connection)
            lock.unlock()
        }
    }
    private func serve(_ descriptor: Int32) {
        do {
            var enabled: Int32 = 1
            guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
                fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
                setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else { return }
            try ControlTransport.verifyPeer(descriptor)
            let limit = ControlTransport.deadline(timeout)
            let data = try ControlTransport.receiveFrame(maximum: ControlTransport.maximumRequestBytes, descriptor: descriptor, until: limit)
            guard let request = try? JSONDecoder().decode(ControlRequest.self, from: data), ControlTransport.valid(request) else { return }
            guard dispatchSlot.wait(timeout: .now()) == .success else {
                let reply = ControlReply(request: request, status: .error, message: "The control action handler is busy.")
                try ControlTransport.sendFrame(JSONEncoder().encode(reply), maximum: ControlTransport.maximumReplyBytes,
                    descriptor: descriptor, until: limit)
                return
            }
            // AF_UNIX peers share one kernel's uptime clock. Honor the client's earlier expiry as well as our own.
            let actionLimit = min(limit, request.deadlineUptimeNanoseconds)
            let action = ControlOperation(request: request, deadline: actionLimit, acknowledge: { [dispatchSlot] in dispatchSlot.signal() })
            lock.lock()
            operation = action
            if stopping { action.cancel() }
            lock.unlock()
            defer { lock.lock(); operation = nil; lock.unlock() }
            delivery.async { [dispatcher, action] in dispatcher(action) }
            guard let reply = action.wait() else { return }
            let encoded = try JSONEncoder().encode(ControlTransport.redacted(reply, for: request))
            // A bounded grace lets the client learn cancellation/unknown outcome instead of seeing only a closed socket.
            try ControlTransport.sendFrame(encoded, maximum: ControlTransport.maximumReplyBytes, descriptor: descriptor,
                until: max(limit, ControlTransport.deadline(0.05)))
        } catch {
            // Malformed, unauthorized and stalled connections receive no payload echo and cannot kill the listener.
        }
    }
}

public enum LocalControlClient {
    public static func send(_ request: ControlRequest, to url: URL, timeout: TimeInterval = 3) throws -> ControlReply {
        guard timeout.isFinite, ControlTransport.valid(request) else { throw LocalControlError.invalidMessage }
        do { _ = try ControlTransport.socketIdentity(url) }
        catch let error as LocalControlError { throw error }
        catch { throw LocalControlError.unavailable }
        var address = try ControlTransport.address(url.path)
        let descriptor = try ControlTransport.makeSocket()
        defer { close(descriptor) }
        let limit = ControlTransport.deadline(timeout)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if connected != 0 {
            guard errno == EINPROGRESS else { throw LocalControlError.unavailable }
            try ControlTransport.wait(descriptor, events: Int16(POLLOUT), until: limit)
            var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
                throw LocalControlError.unavailable
            }
        }
        try ControlTransport.verifyPeer(descriptor)
        let data = try JSONEncoder().encode(request.bounded(until: limit))
        try ControlTransport.sendFrame(data, maximum: ControlTransport.maximumRequestBytes, descriptor: descriptor, until: limit)
        let result = try ControlTransport.receiveFrame(maximum: ControlTransport.maximumReplyBytes, descriptor: descriptor, until: limit)
        guard let reply = try? JSONDecoder().decode(ControlReply.self, from: result), reply.id == request.id else {
            throw LocalControlError.invalidMessage
        }
        return reply
    }
}
#endif
