import Foundation
import RemSoundRuntime

enum RouterHTTPTransport {
    static let deadlineSeconds: TimeInterval = 8
    struct Request {
        fileprivate let url: URL, gateway: String, soap: (UPnPRouterService, UPnPRouterProtocol.Action)?
        let body: Data?
        var action: UPnPRouterProtocol.Action? { soap?.1 }
        static func description(location: URL, gateway: String) -> Request? {
            guard let url = UPnPRouterProtocol.safeURL(location, gateway: gateway) else { return nil }
            return .init(url: url, gateway: gateway, soap: nil, body: nil)
        }
        static func soap(service: UPnPRouterService, action: UPnPRouterProtocol.Action, internalClient: String? = nil,
                         internalPort: UInt16 = 0, externalPort: UInt16 = 0, leaseSeconds: UInt32 = 3600, mappingDescription: String = "RemSound audio") -> Request? {
            guard let request = UPnPRouterProtocol.request(service, action: action, internalClient: internalClient,
                internalPort: internalPort, externalPort: externalPort, leaseSeconds: leaseSeconds, mappingDescription: mappingDescription) else { return nil }
            return .init(url: request.url, gateway: service.gatewayAddress, soap: (service, action), body: request.body)
        }
        fileprivate var mutates: Bool { soap?.1 == .add || soap?.1 == .delete }
        fileprivate var maximumBytes: Int { soap == nil ? UPnPRouterProtocol.maximumDescriptionBytes : UPnPRouterProtocol.maximumSOAPBytes }
    }
    enum Outcome: Equatable {
        case refused, description([UPnPRouterService]), soap(UPnPSOAPReply), failure(String, mutationMayHaveOccurred: Bool)
        var isFailure: Bool { if case .failure = self { return true }; return false }
        var mutationMayHaveOccurred: Bool { if case .failure(_, let value) = self { return value }; return false }
    }
    class RedirectPolicy: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
    static func nativeFetch(_ request: Request, runtime: RuntimeConfiguration, enabled: @escaping () -> Bool,
                            configuration: @escaping () -> URLSessionConfiguration = { .ephemeral },
                            completion: @escaping (Outcome) -> Void) -> () -> Void {
        fetch(request, permitted: { !runtime.isIsolated && enabled() }, configuration: configuration, completion: completion)
    }
    // Completion follows URLSession invalidation, after its task and delegate callbacks quiesce.
    // A lost mutating reply is uncertainty, never evidence that the router rolled back.
    private final class Operation: RedirectPolicy, URLSessionDataDelegate {
        let request: Request
        private let lock = NSLock()
        private var session: URLSession?, task: URLSessionDataTask?, response: HTTPURLResponse?
        private var bytes = Data(), outcome: Outcome?, sent = false
        private var completion: ((Outcome) -> Void)?
        init(_ request: Request, completion: @escaping (Outcome) -> Void) { self.request = request; self.completion = completion }
        func start(configuration: URLSessionConfiguration, timeout: TimeInterval) {
            let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            var wire = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
            wire.httpMethod = request.soap == nil ? "GET" : "POST"
            wire.setValue("text/xml", forHTTPHeaderField: "Accept")
            if let (service, action) = request.soap {
                wire.httpBody = request.body
                wire.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
                wire.setValue("\"\(service.kind.rawValue)#\(action.rawValue)\"", forHTTPHeaderField: "SOAPAction")
            }
            let task = session.dataTask(with: wire)
            lock.lock(); self.session = session; self.task = task; sent = true; task.resume(); lock.unlock()
        }
        func cancel() { finish(.failure("Router HTTP cancelled", mutationMayHaveOccurred: request.mutates)) }
        private func finish(_ value: Outcome) {
            lock.lock()
            guard outcome == nil else { lock.unlock(); return }
            outcome = value
            let session = self.session, task = self.task
            lock.unlock()
            // Immediate invalidation can precede transport stop. Drain the cancelled task first.
            task?.cancel()
            session?.finishTasksAndInvalidate()
        }
        private func fail(_ reason: String) {
            lock.lock(); let uncertain = sent && request.mutates; lock.unlock()
            finish(.failure(reason, mutationMayHaveOccurred: uncertain))
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse, http.url == request.url,
                  http.statusCode == 200 || (request.soap != nil && http.statusCode == 500),
                  response.expectedContentLength >= -1, response.expectedContentLength <= Int64(request.maximumBytes) else {
                completionHandler(.cancel); fail("Router HTTP headers refused"); return
            }
            lock.lock(); let active = outcome == nil; if active { self.response = http }; lock.unlock()
            completionHandler(active ? .allow : .cancel)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            guard outcome == nil else { lock.unlock(); return }
            guard response != nil, data.count <= request.maximumBytes - bytes.count else {
                lock.unlock(); fail("Router HTTP body exceeded limit"); return
            }
            bytes.append(data); lock.unlock()
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock(); let active = outcome == nil, response = self.response, bytes = self.bytes; lock.unlock()
            guard active else { return }
            guard error == nil, let response else { fail("Router HTTP did not complete"); return }
            if let (service, action) = request.soap {
                guard let reply = UPnPRouterProtocol.reply(bytes, status: response.statusCode, service: service, action: action) else {
                    fail("Router SOAP response refused"); return
                }
                finish(.soap(reply))
            } else {
                let services = UPnPRouterProtocol.services(bytes, location: request.url, gatewayAddress: request.gateway)
                guard !services.isEmpty else { fail("Router description has no supported WAN service"); return }
                finish(.description(services))
            }
        }
        func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
            lock.lock()
            let callback = completion, result = outcome ?? .failure("Router HTTP invalidated", mutationMayHaveOccurred: sent && request.mutates)
            completion = nil; self.session = nil; task = nil; response = nil; bytes.removeAll(keepingCapacity: false)
            lock.unlock()
            callback?(result)
        }
    }
    static func fetch(_ request: Request, permitted: @escaping () -> Bool,
                      configuration: () -> URLSessionConfiguration = { .ephemeral }, timeout: TimeInterval = deadlineSeconds,
                      sessionObserver: (URLSessionConfiguration) -> Void = { _ in }, completion: @escaping (Outcome) -> Void) -> () -> Void {
        guard permitted() else { completion(.refused); return {} }
        guard timeout.isFinite, timeout > 0 else { completion(.failure("Invalid Router HTTP deadline", mutationMayHaveOccurred: false)); return {} }
        let timeout = min(timeout, deadlineSeconds)
        let config = configuration()
        config.timeoutIntervalForRequest = timeout; config.timeoutIntervalForResource = timeout
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData; config.connectionProxyDictionary = [:]
        sessionObserver(config)
        guard permitted() else { completion(.refused); return {} }
        let operation = Operation(request, completion: completion)
        operation.start(configuration: config, timeout: timeout)
        return { [weak operation] in operation?.cancel() }
    }
}
