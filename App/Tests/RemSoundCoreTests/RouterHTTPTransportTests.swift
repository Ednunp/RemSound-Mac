import Foundation
import XCTest
import RemSoundRuntime
@testable import RemSoundCore

private final class RouterHTTPProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var load: ((RouterHTTPProtocol) -> Void)?
    private static var stopped: (() -> Void)?
    static func install(_ load: @escaping (RouterHTTPProtocol) -> Void, stopped: @escaping () -> Void = {}) {
        lock.lock(); Self.load = load; Self.stopped = stopped; lock.unlock()
    }
    private var onStop: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let load = Self.load; onStop = Self.stopped; Self.lock.unlock()
        // Per-session interception has no network fallback, including unexpected requests.
        guard request.url?.host == "192.0.2.1", let load else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        load(self)
    }
    override func stopLoading() { onStop?() }
    func response(status: Int = 200, length: Int? = nil, url: URL? = nil) {
        var headers = ["Content-Type": "text/xml"]
        if let length { headers["Content-Length"] = String(length) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url ?? request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
    }
    func bytes(_ data: Data) { client?.urlProtocol(self, didLoad: data) }
    func finish() { client?.urlProtocolDidFinishLoading(self) }
    func fail() { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)) }
}

final class RouterHTTPTransportTests: XCTestCase {
    private let gateway = "192.0.2.1"
    private var service: UPnPRouterService { .init(kind: .ip2, controlURL: URL(string: "http://192.0.2.1:5000/control")!, gatewayAddress: gateway) }
    private func configuration() -> URLSessionConfiguration {
        let value = URLSessionConfiguration.ephemeral; value.protocolClasses = [RouterHTTPProtocol.self]; return value
    }
    private func request(_ action: UPnPRouterProtocol.Action = .externalIP) -> RouterHTTPTransport.Request {
        RouterHTTPTransport.Request.soap(service: service, action: action, internalClient: "192.0.2.10", internalPort: 47830, externalPort: 47830)!
    }
    private func body(_ action: UPnPRouterProtocol.Action = .externalIP, contents: String = "<NewExternalIPAddress>203.0.113.7</NewExternalIPAddress>") -> Data {
        Data("<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><u:\(action.rawValue)Response xmlns:u=\"\(service.kind.rawValue)\">\(contents)</u:\(action.rawValue)Response></s:Body></s:Envelope>".utf8)
    }
    @discardableResult private func fetch(_ request: RouterHTTPTransport.Request? = nil, timeout: TimeInterval = 1, permitted: @escaping () -> Bool = { true }, completion: @escaping (RouterHTTPTransport.Outcome) -> Void) -> () -> Void {
        RouterHTTPTransport.fetch(request ?? self.request(), permitted: permitted, configuration: configuration, timeout: timeout, completion: completion)
    }
    func testOffAndIsolatedRefuseBeforeConfigurationFactory() throws {
        var factories = 0, replies = 0
        let cancel = RouterHTTPTransport.fetch(request(), permitted: { false }, configuration: { factories += 1; return self.configuration() }) { XCTAssertEqual($0, .refused); replies += 1 }
        cancel(); XCTAssertEqual(factories, 0); XCTAssertEqual(replies, 1)
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"]!).appendingPathComponent("router-http-refusal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try RuntimeConfiguration(options: LaunchOptions.parse(["--config-dir", root.path, "--headless", "--silent"]))
        RouterHTTPTransport.nativeFetch(request(), runtime: runtime, enabled: { true }, configuration: { factories += 1; return self.configuration() }) { XCTAssertEqual($0, .refused) }()
        XCTAssertEqual(factories, 0)
    }
    func testInvalidOriginRefusesBeforeFactoryAndSoapBuilderRejectsIt() {
        for text in ["http://example.invalid/x", "http://192.0.2.2/x", "http://user@192.0.2.1/x", "http://192.0.2.1/x#fragment", "file:///x"] {
            XCTAssertNil(RouterHTTPTransport.Request.description(location: URL(string: text)!, gateway: gateway))
        }
        let forged = UPnPRouterService(kind: .ip2, controlURL: URL(string: "http://192.0.2.2/control")!, gatewayAddress: gateway)
        XCTAssertNil(RouterHTTPTransport.Request.soap(service: forged, action: .externalIP))
    }
    func testTypedSoapRequestAndCompleteReply() {
        let done = expectation(description: "typed response")
        RouterHTTPProtocol.install({ transport in
            XCTAssertEqual(transport.request.httpMethod, "POST")
            XCTAssertEqual(transport.request.value(forHTTPHeaderField: "SOAPAction"), "\"\(self.service.kind.rawValue)#GetExternalIPAddress\"")
            XCTAssertEqual(transport.request.timeoutInterval, 1)
            let data = self.body(); transport.response(length: data.count); transport.bytes(data.prefix(20)); transport.bytes(data.dropFirst(20)); transport.finish()
        })
        let cancel = fetch { XCTAssertEqual($0, .soap(.success(externalAddress: "203.0.113.7"))); done.fulfill() }
        wait(for: [done], timeout: 3); cancel()
    }
    func testDescriptionUsesGetAndReturnsBoundedServices() throws {
        let request = try XCTUnwrap(RouterHTTPTransport.Request.description(location: URL(string: "http://192.0.2.1:5000/description")!, gateway: gateway))
        let xml = "<root xmlns=\"urn:schemas-upnp-org:device-1-0\"><device><deviceType>\(UPnPRouterProtocol.igd2)</deviceType><deviceList><device><deviceType>urn:schemas-upnp-org:device:WANDevice:2</deviceType><deviceList><device><deviceType>urn:schemas-upnp-org:device:WANConnectionDevice:2</deviceType><serviceList><service><serviceType>\(service.kind.rawValue)</serviceType><controlURL>/control</controlURL></service></serviceList></device></deviceList></device></deviceList></device></root>"
        let done = expectation(description: "description parsed")
        RouterHTTPProtocol.install({ transport in XCTAssertEqual(transport.request.httpMethod, "GET"); transport.response(); transport.bytes(Data(xml.utf8)); transport.finish() })
        let cancel = fetch(request) { XCTAssertEqual($0, .description([self.service])); done.fulfill() }
        wait(for: [done], timeout: 3); cancel()
    }
    func testSessionHasNoCredentialsCookiesCachesOrProxies() {
        let done = expectation(description: "safe session")
        RouterHTTPProtocol.install({ transport in transport.response(); transport.bytes(self.body()); transport.finish() })
        let cancel = RouterHTTPTransport.fetch(request(), permitted: { true }, configuration: configuration, sessionObserver: { config in
            XCTAssertNil(config.urlCredentialStorage); XCTAssertNil(config.httpCookieStorage); XCTAssertFalse(config.httpShouldSetCookies); XCTAssertNil(config.urlCache)
            XCTAssertEqual(config.connectionProxyDictionary?.count, 0); XCTAssertEqual(config.timeoutIntervalForResource, 8)
        }) { _ in done.fulfill() }
        wait(for: [done], timeout: 3); cancel()
    }
    func testExactSoapCapAcceptedAndLargerHeaderRejected() {
        let original = body(), padded = original + Data(repeating: 32, count: UPnPRouterProtocol.maximumSOAPBytes - original.count)
        for (declared, data, succeeds) in [(padded.count, padded, true), (padded.count + 1, original, false)] {
            let done = expectation(description: "inclusive body limit")
            RouterHTTPProtocol.install({ transport in transport.response(length: declared); transport.bytes(data); transport.finish() })
            let cancel = fetch { if succeeds { XCTAssertEqual($0, .soap(.success(externalAddress: "203.0.113.7"))) } else { XCTAssertTrue($0.isFailure) }; done.fulfill() }
            wait(for: [done], timeout: 3); cancel()
        }
    }
    func testStreamingCapRejectsBeforeParser() {
        let done = expectation(description: "bounded streaming"), stopped = expectation(description: "exact session stopped")
        RouterHTTPProtocol.install({ transport in transport.response(); transport.bytes(Data(repeating: 32, count: UPnPRouterProtocol.maximumSOAPBytes + 1)) }, stopped: { stopped.fulfill() })
        let cancel = fetch(timeout: 5) { XCTAssertTrue($0.isFailure); done.fulfill() }
        wait(for: [done, stopped], timeout: 1); cancel()
    }
    func testDescriptionHasItsOwnLargerStreamCap() throws {
        let request = try XCTUnwrap(RouterHTTPTransport.Request.description(location: URL(string: "http://192.0.2.1/description")!, gateway: gateway))
        let done = expectation(description: "description stream cap"), stopped = expectation(description: "description stopped")
        RouterHTTPProtocol.install({ transport in transport.response(); transport.bytes(Data(repeating: 32, count: UPnPRouterProtocol.maximumDescriptionBytes + 1)) }, stopped: { stopped.fulfill() })
        let cancel = fetch(request, timeout: 5) { XCTAssertTrue($0.isFailure); done.fulfill() }
        wait(for: [done, stopped], timeout: 1); cancel()
    }
    func testBadStatusChangedUrlPartialFailureAndMalformedXmlRefuse() {
        for load: (RouterHTTPProtocol) -> Void in [
            { $0.response(status: 302); $0.finish() },
            { $0.response(url: URL(string: "http://192.0.2.2/control")!); $0.finish() },
            { $0.response(); $0.bytes(Data("partial".utf8)); $0.fail() },
            { $0.response(); $0.bytes(Data("invalid xml".utf8)); $0.finish() }
        ] {
            let done = expectation(description: "invalid response")
            RouterHTTPProtocol.install(load)
            let cancel = fetch { XCTAssertTrue($0.isFailure); done.fulfill() }; wait(for: [done], timeout: 3); cancel()
        }
    }
    func testSoapFaultIsTypedWithoutClaimingMutation() {
        let data = Data("<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><s:Fault><detail><UPnPError xmlns=\"urn:schemas-upnp-org:control-1-0\"><errorCode>714</errorCode><errorDescription>No entry</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>".utf8)
        let done = expectation(description: "specific preflight fault")
        RouterHTTPProtocol.install({ transport in transport.response(status: 500); transport.bytes(data); transport.finish() })
        let cancel = fetch(request(.specificMapping)) { XCTAssertEqual($0, .soap(.fault(code: 714, description: "No entry"))); done.fulfill() }
        wait(for: [done], timeout: 3); cancel()
    }
    func testCancellationReturnsOnceAndStopsProtocol() {
        for _ in 0..<8 {
            let began = expectation(description: "headers pending"), stopped = expectation(description: "native stopped"), done = expectation(description: "quiescent completion")
            stopped.assertForOverFulfill = true; done.assertForOverFulfill = true
            let lock = NSLock(); var events: [String] = []
            RouterHTTPProtocol.install({ _ in
                lock.lock(); events.append("load"); lock.unlock(); began.fulfill()
            }, stopped: {
                lock.lock(); events.append("stop"); lock.unlock(); stopped.fulfill()
            })
            let cancel = fetch(request(.add)) {
                lock.lock(); events.append("completion"); lock.unlock()
                XCTAssertTrue($0.mutationMayHaveOccurred); done.fulfill()
            }
            wait(for: [began], timeout: 2); cancel(); cancel(); wait(for: [stopped, done], timeout: 2)
            // URLProtocol cleanup is not a session delegate callback; its order relative to
            // invalidation varies by SDK. Both cleanup and the single result must complete.
            lock.lock(); let trace = events; lock.unlock()
            XCTAssertEqual(trace.filter { $0 == "load" }.count, 1)
            XCTAssertEqual(trace.filter { $0 == "stop" }.count, 1)
            XCTAssertEqual(trace.filter { $0 == "completion" }.count, 1)
        }
    }
    func testReadCancellationHasNoMutationAndDiscardsPartialBody() {
        let began = expectation(description: "partial read"), stopped = expectation(description: "read stopped"), done = expectation(description: "no partial result")
        RouterHTTPProtocol.install({ transport in transport.response(); transport.bytes(Data("<".utf8)); began.fulfill() }, stopped: { stopped.fulfill() })
        let cancel = fetch { XCTAssertTrue($0.isFailure); XCTAssertFalse($0.mutationMayHaveOccurred); done.fulfill() }
        wait(for: [began], timeout: 2); cancel(); wait(for: [stopped, done], timeout: 2)
    }
    func testDeadlineBoundsStalledHeadersAndBodyWithoutFallback() {
        for partial in [false, true] {
            let stopped = expectation(description: "deadline stop"), done = expectation(description: "finite completion")
            RouterHTTPProtocol.install({ transport in if partial { transport.response(); transport.bytes(Data("<".utf8)) } }, stopped: { stopped.fulfill() })
            let cancel = fetch(timeout: 0.1) { XCTAssertTrue($0.isFailure); done.fulfill() }
            wait(for: [done, stopped], timeout: 0.8); cancel()
        }
    }
    func testPermissionWithdrawnDuringConfigurationDoesNotSend() {
        var enabled = true, loads = 0
        RouterHTTPProtocol.install({ _ in loads += 1 })
        let done = expectation(description: "configuration race refusal")
        let cancel = RouterHTTPTransport.fetch(request(.add), permitted: { enabled }, configuration: { enabled = false; return self.configuration() }) { XCTAssertEqual($0, .refused); done.fulfill() }
        wait(for: [done], timeout: 1); cancel(); XCTAssertEqual(loads, 0)
    }
    func testInvalidDeadlineRefusesBeforeFactoryAndLongDeadlineIsClamped() {
        var factories = 0
        for timeout in [0, -1, TimeInterval.infinity, TimeInterval.nan] {
            let cancel = RouterHTTPTransport.fetch(request(), permitted: { true }, configuration: { factories += 1; return self.configuration() }, timeout: timeout) {
                XCTAssertTrue($0.isFailure); XCTAssertFalse($0.mutationMayHaveOccurred)
            }
            cancel()
        }
        XCTAssertEqual(factories, 0)
        let done = expectation(description: "long deadline clamped")
        RouterHTTPProtocol.install({ transport in
            XCTAssertEqual(transport.request.timeoutInterval, RouterHTTPTransport.deadlineSeconds)
            transport.response(); transport.bytes(self.body()); transport.finish()
        })
        let cancel = fetch(timeout: 100) { XCTAssertEqual($0, .soap(.success(externalAddress: "203.0.113.7"))); done.fulfill() }
        wait(for: [done], timeout: 2); cancel()
    }
    func testNativeDelegateRefusesRedirectAndAuthentication() {
        let owner = RouterHTTPTransport.RedirectPolicy()
        let session = URLSession(configuration: configuration())
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: service.controlURL)
        let response = HTTPURLResponse(url: service.controlURL, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil)!
        owner.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: service.controlURL)) { XCTAssertNil($0) }
        let space = URLProtectionSpace(host: gateway, port: 80, protocol: "http", realm: "fixture", authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: 0, failureResponse: nil, error: nil, sender: ChallengeSender())
        owner.urlSession(session, task: task, didReceive: challenge) { disposition, credential in XCTAssertEqual(disposition, .cancelAuthenticationChallenge); XCTAssertNil(credential) }
    }
    private final class ChallengeSender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }
}
