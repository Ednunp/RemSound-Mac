import Foundation
import XCTest
import RemSoundJam
@testable import RemSoundApp

private final class ServerReleaseProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var active: Fixture?
    final class Fixture {
        let load: (ServerReleaseProtocol) -> Void
        let stopped: () -> Void
        init(load: @escaping (ServerReleaseProtocol) -> Void, stopped: @escaping () -> Void = {}) {
            self.load = load; self.stopped = stopped
        }
    }
    private var fixture: Fixture?
    static func install(_ fixture: Fixture?) { lock.lock(); active = fixture; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); fixture = Self.active; Self.lock.unlock()
        // Every request is intercepted; unexpected requests fail here and cannot reach the network.
        guard request.url == ServerVersionCheck.releaseListURL, let fixture else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        fixture.load(self)
    }
    override func stopLoading() { fixture?.stopped() }
    func response(status: Int = 200, length: Int? = nil, url: URL = ServerVersionCheck.releaseListURL) {
        var headers = ["Content-Type": "application/json"]
        if let length { headers["Content-Length"] = String(length) }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }
    func data(_ data: Data) { client?.urlProtocol(self, didLoad: data) }
    func finish() { client?.urlProtocolDidFinishLoading(self) }
    func fail() { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)) }
}

final class ServerReleaseNativeTransportTests: XCTestCase {
    override func tearDown() { ServerReleaseProtocol.install(nil); super.tearDown() }
    private func configuration() -> URLSessionConfiguration {
        let value = URLSessionConfiguration.ephemeral
        value.protocolClasses = [ServerReleaseProtocol.self]
        return value
    }
    private func fetch(timeout: TimeInterval = 1, _ reply: @escaping (Data?) -> Void) -> () -> Void {
        ServerReleaseLookup.nativeFetch(reply, configuration: configuration(), requestTimeout: timeout)
    }
    func testNativeBytesReturnsCompleteBodyAndUsesServerRequest() {
        let body = Data("[{\"tag_name\":\"server-v2.18\",\"draft\":false,\"prerelease\":false}]".utf8)
        let done = expectation(description: "complete bounded body")
        ServerReleaseProtocol.install(.init(load: { transport in
            XCTAssertEqual(transport.request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            XCTAssertEqual(transport.request.timeoutInterval, 1)
            transport.response(length: body.count); transport.data(body.prefix(5)); transport.data(body.dropFirst(5)); transport.finish()
        }))
        let cancel = fetch { data in XCTAssertEqual(data, body); done.fulfill() }
        defer { cancel() }; wait(for: [done], timeout: 3)
    }
    func testNativeBytesAcceptsExactLimit() {
        let body = Data(repeating: 32, count: ServerReleaseLookup.maximumBytes)
        let done = expectation(description: "inclusive maximum")
        ServerReleaseProtocol.install(.init(load: { transport in transport.response(); transport.data(body); transport.finish() }))
        let cancel = fetch(timeout: 5) { data in XCTAssertEqual(data?.count, body.count); done.fulfill() }
        defer { cancel() }; wait(for: [done], timeout: 8)
    }
    func testStreamingOverflowCancelsUnknownLengthResponse() {
        let done = expectation(description: "oversize refuses partial body"), stopped = expectation(description: "oversize stream stopped")
        ServerReleaseProtocol.install(.init(load: { transport in
            transport.response(); transport.data(Data(repeating: 32, count: ServerReleaseLookup.maximumBytes + 1))
        }, stopped: { stopped.fulfill() }))
        let cancel = fetch(timeout: 5) { data in XCTAssertNil(data); done.fulfill() }
        defer { cancel() }; wait(for: [done, stopped], timeout: 2)
    }
    func testBadStatusHostLengthAndPartialFailureNeverReturnData() {
        let bodies: [(ServerReleaseProtocol) -> Void] = [
            { $0.response(status: 503); $0.data(Data("[]".utf8)); $0.finish() },
            { $0.response(url: URL(string: "https://example.invalid/releases")!); $0.finish() },
            { $0.response(length: ServerReleaseLookup.maximumBytes + 1); $0.finish() },
            { $0.response(); $0.data(Data("partial".utf8)); $0.fail() }
        ]
        for body in bodies {
            let done = expectation(description: "reject invalid native response")
            ServerReleaseProtocol.install(.init(load: body))
            let cancel = fetch { data in XCTAssertNil(data); done.fulfill() }
            wait(for: [done], timeout: 3); cancel()
        }
    }
    func testCancellationBeforeHeadersClosesExactTransport() {
        let began = expectation(description: "pending headers"), stopped = expectation(description: "cancelled native stream"), done = expectation(description: "cancelled reply")
        ServerReleaseProtocol.install(.init(load: { _ in began.fulfill() }, stopped: { stopped.fulfill() }))
        let cancel = fetch { data in XCTAssertNil(data); done.fulfill() }
        wait(for: [began], timeout: 2); cancel(); cancel(); wait(for: [done, stopped], timeout: 2)
    }
    func testDeadlineClosesStalledHeadersWithoutNetworkFallback() {
        let began = expectation(description: "stalled headers"), stopped = expectation(description: "deadline closes headers"), done = expectation(description: "bounded deadline reply")
        ServerReleaseProtocol.install(.init(load: { _ in began.fulfill() }, stopped: { stopped.fulfill() }))
        let cancel = fetch(timeout: 0.1) { data in XCTAssertNil(data); done.fulfill() }
        defer { cancel() }; wait(for: [began, done, stopped], timeout: 0.8)
    }
    func testCancellationDuringBodyRejectsPartialBytesAndStopsStream() {
        let began = expectation(description: "partial response"), stopped = expectation(description: "cancelled body"), done = expectation(description: "no partial result")
        ServerReleaseProtocol.install(.init(load: { transport in
            transport.response(); transport.data(Data("[".utf8)); began.fulfill()
        }, stopped: { stopped.fulfill() }))
        let cancel = fetch { data in XCTAssertNil(data); done.fulfill() }
        wait(for: [began], timeout: 2); cancel(); cancel(); wait(for: [done, stopped], timeout: 2)
    }
    func testDeadlineIncludesBodyStreamingAndRejectsPartialBody() {
        let stopped = expectation(description: "deadline closes body"), done = expectation(description: "bounded body reply")
        ServerReleaseProtocol.install(.init(load: { transport in transport.response(); transport.data(Data("[".utf8)) }, stopped: { stopped.fulfill() }))
        let cancel = fetch(timeout: 0.1) { data in XCTAssertNil(data); done.fulfill() }
        defer { cancel() }; wait(for: [done, stopped], timeout: 0.8)
    }
}
