import Foundation
import RemSoundRuntime
import XCTest
@testable import RemSoundCore

final class RouterDiscoveryTests: XCTestCase {
    private final class Transport: RouterUDPTransport {
        var localAddress: String? = "192.0.2.10"
        var sent: [(Data, Endpoint)] = [], incoming: [(Data, Endpoint)] = []
        var closes = 0, reads = 0, succeeds = true
        var onReceive: (() -> Void)?, onSend: (() -> Void)?
        func send(_ data: Data, to: Endpoint) -> Bool { sent.append((data, to)); onSend?(); return succeeds }
        func receive() -> (Data, Endpoint)? { reads += 1; onReceive?(); return incoming.isEmpty ? nil : incoming.removeFirst() }
        func close() { closes += 1 }
    }
    private final class Fixture {
        var now: TimeInterval = 0, permitted = true, routeCalls = 0, factories = 0
        var route: RouterGatewayRoute? = .init(gateway: Endpoint("192.0.2.1", 5351), sourceAddress: "192.0.2.10", interface: "fixture")
        let transport = Transport()
        var results: [RouterDiscovery.Outcome] = [], closesAtReceipt: [Int] = []
        var onRoute: (() -> Void)?, onFactory: (() -> Void)?
        func operation(timeout: TimeInterval = 2, mode: RouterDiscovery.Mode = .unicast) -> RouterDiscovery {
            RouterDiscovery(timeout: timeout, mode: mode, permitted: { self.permitted }, clock: { self.now }, route: {
                self.routeCalls += 1; self.onRoute?(); return self.route
            }, transport: { _, _ in self.factories += 1; self.onFactory?(); return self.transport }, completion: {
                self.closesAtReceipt.append(self.transport.closes); self.results.append($0)
            })
        }
        func response(target: String = UPnPRouterProtocol.igd1, location: String = "http://192.0.2.1:5000/description.xml") -> Data {
            Data("HTTP/1.1 200 OK\r\nST: \(target)\r\nUSN: uuid:fixture::\(target)\r\nLOCATION: \(location)\r\n\r\n".utf8)
        }
        func enqueue(_ data: Data? = nil, source: String = "192.0.2.1") { transport.incoming.append((data ?? response(), Endpoint(source, 1900))) }
    }
    func testOffRefusesBeforeRouteOrTransport() {
        let f = Fixture(); f.permitted = false; let op = f.operation(); op.tick(); op.cancel()
        XCTAssertEqual(f.results, [.refused]); XCTAssertEqual(f.factories, 0); XCTAssertEqual(f.routeCalls, 0)
    }
    func testNativeConvenienceRefusesIsolatedBeforeAnyDiscovery() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent("router-discovery-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = try RuntimeConfiguration(options: LaunchOptions.parse(["--config-dir", root.path, "--headless", "--silent"]))
        let f = Fixture(), op = RouterDiscovery(configuration: config, enabled: { true }, route: f.route!, completion: { f.results.append($0) })
        op.tick(); XCTAssertEqual(f.results, [.refused])
    }
    func testInvalidBudgetNeverConstructsTransport() {
        for budget: TimeInterval in [0, 0.999, -.infinity, .nan] {
            let f = Fixture(), op = f.operation(timeout: budget); op.tick()
            XCTAssertEqual(f.factories, 0); XCTAssertEqual(f.routeCalls, 0); guard case .failure? = f.results.first else { XCTFail("Invalid budget accepted"); continue }
        }
    }
    func testMissingInvalidRouteAndWrongBindingRefuseSending() {
        for route: RouterGatewayRoute? in [nil, .init(gateway: Endpoint("router.invalid", 5351), sourceAddress: "192.0.2.10", interface: "fixture"), .init(gateway: Endpoint("192.0.2.1", 5351), sourceAddress: "192.0.2.10", interface: "")] {
            let f = Fixture(); f.route = route; let op = f.operation(); op.tick()
            XCTAssertEqual(f.results, [.unavailable]); XCTAssertEqual(f.factories, 0)
        }
        let f = Fixture(); f.transport.localAddress = "192.0.2.11"; let op = f.operation(); op.tick()
        XCTAssertTrue(f.transport.sent.isEmpty); XCTAssertEqual(f.transport.closes, 1)
    }
    func testUnicastPacketNamesActualGatewayWithoutMulticastMx() {
        let f = Fixture(), op = f.operation(); defer { op.cancel() }; op.tick()
        XCTAssertEqual(f.transport.sent.first?.1, Endpoint("192.0.2.1", 1900))
        let text = f.transport.sent.first.map { String(decoding: $0.0, as: UTF8.self) } ?? ""
        XCTAssertTrue(text.contains("HOST: 192.0.2.1:1900\r\n")); XCTAssertTrue(text.contains("ST: \(UPnPRouterProtocol.igd1)\r\n\r\n"))
        XCTAssertFalse(text.contains("MX:")); XCTAssertFalse(text.contains("239.255.255.250"))
    }
    func testMulticastPacketUsesOneSecondMxAndSelectedSource() {
        let f = Fixture(), op = f.operation(mode: .multicast); defer { op.cancel() }; op.tick()
        XCTAssertEqual(f.transport.sent.first?.1, Endpoint("239.255.255.250", 1900))
        let text = f.transport.sent.first.map { String(decoding: $0.0, as: UTF8.self) } ?? ""
        XCTAssertTrue(text.contains("HOST: 239.255.255.250:1900\r\n")); XCTAssertTrue(text.contains("MX: 1\r\n")); XCTAssertEqual(f.transport.localAddress, f.route?.sourceAddress)
    }
    func testExactRetryCountAndOneSecondResponseWindowStayFinite() {
        let f = Fixture(), op = f.operation(); op.tick()
        for (time, count) in [(0.499, 1), (0.5, 2), (1.0, 2), (1.999, 2)] { f.now = time; op.tick(); XCTAssertEqual(f.transport.sent.count, count) }
        XCTAssertEqual(f.transport.sent.first?.0, f.transport.sent.last?.0)
        f.now = 2; op.tick(); op.tick(); XCTAssertEqual(f.results, [.timedOut]); XCTAssertEqual(f.transport.closes, 1)
    }
    func testShortValidBudgetDoesNotRetryWithoutFullResponseWindow() {
        let f = Fixture(), op = f.operation(timeout: 1); op.tick(); f.now = 0.5; op.tick(); f.now = 1; op.tick()
        XCTAssertEqual(f.transport.sent.count, 1); XCTAssertEqual(f.results, [.timedOut])
    }
    func testBudgetIsCappedAtEightSecondsWithoutPerpetualRetransmit() {
        let f = Fixture(), op = f.operation(timeout: 100); op.tick(); f.now = 0.5; op.tick(); f.now = 8; op.tick()
        XCTAssertEqual(f.results, [.timedOut]); XCTAssertEqual(f.transport.sent.count, 2)
    }
    func testMatchingGatewayResponseClosesBeforeSingleReceipt() {
        let f = Fixture(), op = f.operation(); op.tick(); f.enqueue(); op.tick(); op.cancel(); op.tick()
        XCTAssertEqual(f.results, [.found(URL(string: "http://192.0.2.1:5000/description.xml")!)]); XCTAssertEqual(f.closesAtReceipt, [1]); XCTAssertEqual(f.transport.closes, 1)
    }
    func testWrongSourceTargetAndLocationNeverComplete() {
        let f = Fixture(), op = f.operation(); defer { op.cancel() }; op.tick()
        f.enqueue(source: "192.0.2.2"); f.enqueue(f.response(target: UPnPRouterProtocol.igd2)); f.enqueue(f.response(location: "http://192.0.2.2/description.xml"))
        op.tick(); XCTAssertTrue(f.results.isEmpty); f.enqueue(); op.tick(); XCTAssertEqual(f.results.count, 1)
    }
    func testResponsesQueuedBeforeFirstSendAreNotConsumedAsThisVisit() {
        let f = Fixture(), op = f.operation(); f.enqueue(); op.tick()
        // There is no SSDP request id. A new socket scopes the visit, and reception
        // starts only after its first send; the initial tick must not accept data.
        XCTAssertTrue(f.results.isEmpty); XCTAssertEqual(f.transport.reads, 0); op.cancel()
    }
    func testNoiseReadsAndWholeVisitPacketCapAreBounded() {
        let f = Fixture(), op = f.operation(); op.tick()
        for _ in 0..<100 { f.enqueue(source: "192.0.2.2") }
        let before = f.transport.reads; op.tick(); XCTAssertEqual(f.transport.reads - before, 16)
        for _ in 0..<4 { op.tick() }
        guard case .failure? = f.results.first else { return XCTFail("Visit packet budget exhausted without stopping") }
        XCTAssertEqual(f.transport.reads - before, 64); XCTAssertEqual(f.transport.closes, 1)
    }
    func testOversizedDatagramsCannotReachParserAndByteBudgetStopsVisit() {
        let f = Fixture(), op = f.operation(); op.tick()
        for _ in 0..<5 { f.enqueue(Data(repeating: 65, count: 65535)) }
        op.tick(); guard case .failure? = f.results.first else { return XCTFail("Byte cap did not stop noise") }
        XCTAssertEqual(f.transport.closes, 1)
    }
    func testCancelBeforeTickNeverConstructsAndNeverRetries() {
        let f = Fixture(), op = f.operation(); op.cancel(); op.tick(); op.cancel()
        XCTAssertEqual(f.results, [.cancelled]); XCTAssertEqual(f.factories, 0); XCTAssertEqual(f.routeCalls, 0)
    }
    func testPermissionAndDeadlineRetirementDiscardBufferedLocation() {
        for timedOut in [false, true] {
            let f = Fixture(), op = f.operation(); op.tick(); f.enqueue()
            if timedOut { f.now = 2 } else { f.permitted = false }; op.tick()
            XCTAssertEqual(f.results, [timedOut ? .timedOut : .cancelled]); XCTAssertEqual(f.transport.closes, 1)
        }
    }
    func testRouteSelectionRetirementCannotConstructSocket() {
        let f = Fixture(), op = f.operation(); f.onRoute = { f.permitted = false }; op.tick(); f.onRoute = nil
        XCTAssertEqual(f.factories, 0); XCTAssertEqual(f.results, [.refused])
    }
    func testFactoryCancellationCompletesOnlyAfterReturnedSocketCloses() {
        let f = Fixture(), op = f.operation(); f.onFactory = { op.cancel(); XCTAssertTrue(f.results.isEmpty) }; op.tick(); f.onFactory = nil
        XCTAssertEqual(f.results, [.cancelled]); XCTAssertEqual(f.closesAtReceipt, [1]); XCTAssertEqual(f.transport.closes, 1); XCTAssertTrue(f.transport.sent.isEmpty)
    }
    func testReceiveReentrantCancellationCannotPublishLocation() {
        let f = Fixture(), op = f.operation(); op.tick(); f.enqueue(); f.transport.onReceive = { op.cancel(); XCTAssertTrue(f.results.isEmpty) }; op.tick(); f.transport.onReceive = nil
        XCTAssertEqual(f.results, [.cancelled]); XCTAssertEqual(f.transport.closes, 1)
    }
    func testSendReentrantCancellationWaitsForReturnBeforeReceipt() {
        let f = Fixture(), op = f.operation(); f.transport.onSend = { op.cancel(); XCTAssertTrue(f.results.isEmpty); op.tick() }; op.tick(); f.transport.onSend = nil
        XCTAssertEqual(f.results, [.cancelled]); XCTAssertEqual(f.closesAtReceipt, [1]); XCTAssertEqual(f.transport.sent.count, 1)
    }
    func testPermissionAndDeadlineAreRecheckedAfterFactory() {
        for expired in [false, true] {
            let f = Fixture(), op = f.operation(); f.onFactory = { if expired { f.now = 2 } else { f.permitted = false } }; op.tick(); f.onFactory = nil
            XCTAssertTrue(f.transport.sent.isEmpty); XCTAssertEqual(f.transport.closes, 1); XCTAssertEqual(f.results, [expired ? .timedOut : .cancelled])
        }
    }
    func testFailedSendAndOwnerReleaseCleanExactSocket() {
        let f = Fixture(); f.transport.succeeds = false; let op = f.operation(); op.tick()
        guard case .failure? = f.results.first else { return XCTFail("Send failure ignored") }; XCTAssertEqual(f.transport.closes, 1)
        let second = Fixture(); var pending: RouterDiscovery? = second.operation(); pending?.tick(); pending = nil
        XCTAssertEqual(second.results, [.cancelled]); XCTAssertEqual(second.transport.closes, 1)
    }
    func testNonfiniteAndBackwardClockFailWithoutMorePackets() {
        for time: TimeInterval in [.nan, -.infinity, -1] {
            let f = Fixture(), op = f.operation(); op.tick(); f.now = time; op.tick()
            guard case .failure? = f.results.first else { XCTFail("Invalid clock ignored"); continue }; XCTAssertEqual(f.transport.sent.count, 1); XCTAssertEqual(f.transport.closes, 1)
        }
    }
    func testUnicastSearchRejectsNonNumericMulticastAndInvalidTarget() {
        for address in ["router.invalid", "127.0.0.1", "239.255.255.250", "192.0.2.1\r\nBad: value"] { XCTAssertNil(UPnPRouterProtocol.unicastSearch(gatewayAddress: address)) }
        XCTAssertNil(UPnPRouterProtocol.unicastSearch(gatewayAddress: "192.0.2.1", target: "ssdp:all"))
        XCTAssertNil(UPnPRouterProtocol.search(mx: 0)); XCTAssertNil(UPnPRouterProtocol.search(mx: 6))
    }
    func testNativeMulticastOptionsAndOwnedSpareLoopbackClose() throws {
        let multicast = try NativeRouterDiscoveryTransport(sourceAddress: "127.0.0.1", mode: .multicast)
        XCTAssertEqual(multicast.multicastSettings?.sourceAddress, "127.0.0.1"); XCTAssertEqual(multicast.multicastSettings?.ttl, 2)
        XCTAssertFalse([1900, 5351, 47821, 47830, 47831].contains(multicast.boundPort)); multicast.close(); XCTAssertNil(multicast.localAddress)
        let listener = try UDP(port: 0, loopback: true), transport = try NativeRouterDiscoveryTransport(sourceAddress: "127.0.0.1", mode: .unicast)
        defer { transport.close() }
        XCTAssertFalse([1900, 5351, 47821, 47830, 47831].contains(listener.boundPort)); XCTAssertNil(transport.multicastSettings)
        let bytes = Data("owned discovery transport fixture".utf8), released = transport.boundPort
        XCTAssertTrue(transport.send(bytes, to: Endpoint("127.0.0.1", listener.boundPort)))
        var receipt: (Data, Endpoint)?; let deadline = ProcessInfo.processInfo.systemUptime + 1
        while receipt == nil && ProcessInfo.processInfo.systemUptime < deadline { receipt = listener.receive(); if receipt == nil { Thread.sleep(forTimeInterval: 0.001) } }
        XCTAssertEqual(receipt?.0, bytes); XCTAssertEqual(receipt?.1.address, "127.0.0.1")
        transport.close(); transport.close(); XCTAssertNil(transport.localAddress)
        let rebound = try UDP(port: released, loopback: true); XCTAssertEqual(rebound.boundPort, released)
    }
}
