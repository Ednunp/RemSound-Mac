import Foundation
import RemSoundRuntime
import XCTest
@testable import RemSoundCore

final class RouterUDPExchangeTests: XCTestCase {
    private final class Transport: RouterUDPTransport {
        var localAddress: String? = "192.0.2.10"
        var sent: [(Data,Endpoint)] = [], incoming: [(Data,Endpoint)] = []
        var closes = 0, reads = 0, sendSucceeds = true
        func send(_ packet: Data, to: Endpoint) -> Bool { sent.append((packet,to));return sendSucceeds }
        func receive() -> (Data,Endpoint)? { reads += 1;return incoming.isEmpty ? nil : incoming.removeFirst() }
        func close() { closes += 1 }
    }
    private final class Fixture {
        var now: TimeInterval = 0, permitted = true, routeCalls = 0, factories = 0
        var route: RouterGatewayRoute? = .init(gateway:Endpoint("192.0.2.1",5351),sourceAddress:"192.0.2.10",interface:"fixture")
        let transport = Transport()
        var results: [RouterUDPExchange.Outcome] = []
        var closedAtCompletion: [Int] = []
        var onRoute: (() -> Void)?, onFactory: (() -> Void)?
        func operation(_ request: RouterUDPExchange.Request = .natAddress) -> RouterUDPExchange {
            RouterUDPExchange(request:request,permitted:{self.permitted},clock:{self.now},route:{self.routeCalls += 1;self.onRoute?();return self.route},transport:{_ in self.factories += 1;self.onFactory?();return self.transport},jitter:{0},completion:{self.closedAtCompletion.append(self.transport.closes);self.results.append($0)})
        }
        func announce(_ epoch: UInt8 = 7) -> Data { var b=Data(repeating:0,count:24);b[0]=2;b[1]=128;b[11]=epoch;return b }
        func map() -> Data { Data([0,129,0,0,0,0,0,7,0xba,0xd6,0xc0,0xa9,0,0,14,16]) }
        func address() -> Data { Data([0,128,0,0,0,0,0,7,203,0,113,7]) }
        func enqueue(_ data: Data) { transport.incoming.append((data,Endpoint("192.0.2.1",5351))) }
    }
    func testOffRefusesBeforeRouteOrSocketFactory() {
        let f=Fixture();f.permitted=false;let op=f.operation();op.tick();op.tick();op.cancel()
        XCTAssertEqual(f.routeCalls,0);XCTAssertEqual(f.factories,0);XCTAssertEqual(f.results,[.refused])
    }
    func testNativeConvenienceRefusesIsolatedConfiguration() throws {
        let root=URL(fileURLWithPath:ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent("router-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let config=try RuntimeConfiguration(options:LaunchOptions.parse(["--config-dir",root.path,"--headless","--silent"]))
        var results:[RouterUDPExchange.Outcome]=[]
        let op=RouterUDPExchange(request:.natAddress,configuration:config,enabled:{true},completion:{results.append($0)})
        op.tick();XCTAssertEqual(results,[.refused])
    }
    func testMissingOrInvalidRouteNeverConstructsSocket() {
        for route: RouterGatewayRoute? in [nil,.init(gateway:Endpoint("example.invalid",5351),sourceAddress:"192.0.2.10",interface:"fixture"),.init(gateway:Endpoint("192.0.2.1",5350),sourceAddress:"192.0.2.10",interface:"fixture") ] {
            let f=Fixture();f.route=route;let op=f.operation();op.tick()
            XCTAssertEqual(f.factories,0);XCTAssertEqual(f.results,[.unavailable])
        }
    }
    func testSocketMustBindTheChosenLocalSourceBeforeAnySend() {
        let f=Fixture();f.transport.localAddress="192.0.2.11";let op=f.operation();op.tick()
        XCTAssertTrue(f.transport.sent.isEmpty);XCTAssertEqual(f.transport.closes,1);XCTAssertEqual(f.results.count,1)
    }
    func testInvalidMapCannotReadRouteOrDeleteEveryPort() {
        let f=Fixture();let op=f.operation(.natMap(internalPort:0,externalPort:0,lifetime:0));op.tick()
        XCTAssertEqual(f.routeCalls,0);XCTAssertEqual(f.factories,0);XCTAssertEqual(f.results.count,1)
    }
    func testNatRetryScheduleAndExactRequestStayBounded() {
        let f=Fixture();let op=f.operation();defer{op.cancel()};op.tick()
        for (time,count) in [(0.249,1),(0.25,2),(0.749,2),(0.75,3),(1.75,4),(3.75,5),(7.75,6)] {
            f.now=time;op.tick();XCTAssertEqual(f.transport.sent.count,count)
        }
        XCTAssertTrue(f.transport.sent.allSatisfy{$0.0==Data([0,0]) && $0.1.port==5351})
        f.now=8;op.tick();XCTAssertEqual(f.results,[.timedOut(mutationMayHaveOccurred:false)]);XCTAssertEqual(f.transport.closes,1)
    }
    func testPcpAnnounceIsNonMutatingWithThreeSecondInitialRetry() {
        let f=Fixture();let op=f.operation(.pcpAnnounce);defer{op.cancel()};op.tick()
        let packet=f.transport.sent.first?.0;XCTAssertEqual(packet?.count,24);XCTAssertEqual(packet?.prefix(8),Data([2,0,0,0,0,0,0,0]))
        f.now=2.999;op.tick();XCTAssertEqual(f.transport.sent.count,1)
        f.now=3;op.tick();XCTAssertEqual(f.transport.sent.count,2)
        f.now=8;op.tick();XCTAssertEqual(f.results,[.timedOut(mutationMayHaveOccurred:false)])
    }
    func testMatchingResponseClosesBeforeOneCompletionAndNoMorePackets() {
        let f=Fixture();let op=f.operation();op.tick();f.enqueue(f.address());op.tick();op.tick();op.cancel()
        XCTAssertEqual(f.results.count,1);XCTAssertEqual(f.transport.closes,1);XCTAssertEqual(f.transport.sent.count,1)
        XCTAssertEqual(f.closedAtCompletion,[1])
        if case let .response(value,route)? = f.results.first { XCTAssertEqual(value.externalAddress,"203.0.113.7");XCTAssertEqual(route,f.route) } else { XCTFail("Expected a matched reply") }
    }
    func testWrongGatewayAndBoundedNoiseCannotCompleteRequest() {
        let f=Fixture();let op=f.operation();defer{op.cancel()};op.tick()
        for _ in 0..<40 { f.transport.incoming.append((f.address(),Endpoint("192.0.2.2",5351))) }
        let before=f.transport.reads;op.tick();XCTAssertEqual(f.transport.reads-before,16);XCTAssertTrue(f.results.isEmpty)
    }
    func testCancelBeforeStartCompletesWithoutConstructingAnything() {
        let f=Fixture();let op=f.operation();op.cancel();op.cancel();op.tick()
        XCTAssertEqual(f.routeCalls,0);XCTAssertEqual(f.factories,0);XCTAssertEqual(f.results,[.cancelled(mutationMayHaveOccurred:false)])
    }
    func testCancelReturnsQueuedLateGrantForCleanup() {
        let f=Fixture();let op=f.operation(.natMap(internalPort:47830,externalPort:47830,lifetime:3600));op.tick();f.enqueue(f.map());op.cancel()
        if case let .lateResponse(value,_)?=f.results.first { XCTAssertEqual(value.externalPort,49321) } else { XCTFail("Late grant must be returned for exact cleanup") }
        XCTAssertEqual(f.transport.closes,1);XCTAssertEqual(f.transport.sent.count,1)
    }
    func testLostMapReplyReportsUncertaintyAndNeverGuessesProtocolFallback() {
        let f=Fixture();let op=f.operation(.natMap(internalPort:47830,externalPort:47830,lifetime:3600));op.tick();f.now=8;op.tick()
        XCTAssertEqual(f.results,[.timedOut(mutationMayHaveOccurred:true)]);XCTAssertEqual(f.transport.sent.count,1)
    }
    func testPermissionRetirementStopsSendingAndReportsPendingMutation() {
        let f=Fixture();let op=f.operation(.natMap(internalPort:47830,externalPort:47830,lifetime:3600));op.tick();f.permitted=false;f.now=1;op.tick()
        XCTAssertEqual(f.results,[.cancelled(mutationMayHaveOccurred:true)]);XCTAssertEqual(f.transport.sent.count,1);XCTAssertEqual(f.transport.closes,1)
    }
    func testFailedSendDoesNotClaimRemoteMutationAndDeinitClosesPendingSocket() {
        let f=Fixture();f.transport.sendSucceeds=false
        var op:RouterUDPExchange?=f.operation(.natMap(internalPort:47830,externalPort:47830,lifetime:3600));op?.tick();op=nil
        if case let .failed(_,mutated)?=f.results.first { XCTAssertFalse(mutated) } else { XCTFail("Expected send failure") }
        XCTAssertEqual(f.transport.closes,1);XCTAssertEqual(f.results.count,1)
        let second=Fixture();var pending:RouterUDPExchange?=second.operation();pending?.tick();pending=nil
        XCTAssertEqual(second.transport.closes,1);XCTAssertEqual(second.results,[.cancelled(mutationMayHaveOccurred:false)])
    }
    func testUnsupportedVersionReplyRetainedForSafeLaterFallback() {
        let f=Fixture();let op=f.operation(.pcpAnnounce);op.tick();f.enqueue(Data([0,128,0,1,0,0,0,7]));op.tick()
        if case let .response(value,_)?=f.results.first { XCTAssertEqual(value.resultCode,1) } else { XCTFail("Expected explicit unsupported-version reply") }
    }
    func testNativeBoundTransportUsesOwnedSpareLoopbackAndClosesExactly() throws {
        let listener=try UDP(port:0,loopback:true), transport=try NativeRouterUDPTransport(sourceAddress:"127.0.0.1")
        defer{transport.close()};XCTAssertEqual(transport.localAddress,"127.0.0.1")
        for port in [listener.boundPort,transport.boundPort] { XCTAssertFalse([5351,47821,47830,47831].contains(port)) }
        let payload=Data("owned router transport fixture".utf8)
        XCTAssertTrue(transport.send(payload,to:Endpoint("127.0.0.1",listener.boundPort)))
        var received:(Data,Endpoint)?;let deadline=ProcessInfo.processInfo.systemUptime+1
        while received==nil && ProcessInfo.processInfo.systemUptime<deadline { received=listener.receive();if received==nil {Thread.sleep(forTimeInterval:0.001)} }
        XCTAssertEqual(received?.0,payload);XCTAssertEqual(received?.1.address,"127.0.0.1")
        let releasedPort=transport.boundPort
        transport.close();transport.close();XCTAssertNil(transport.localAddress);XCTAssertFalse(transport.send(payload,to:Endpoint("127.0.0.1",listener.boundPort)))
        let rebound=try UDP(port:releasedPort,loopback:true);XCTAssertEqual(rebound.boundPort,releasedPort)
    }
    func testUdpBindingRejectsMalformedAndConflictingLoopbackChoice() {
        XCTAssertThrowsError(try UDP(port:0,localAddress:"example.invalid"))
        XCTAssertThrowsError(try UDP(port:0,loopback:true,localAddress:"192.0.2.10"))
    }
    func testPermissionAndDeadlineRecheckedAfterRouteSelection() {
        let f=Fixture();f.onRoute={f.permitted=false};let op=f.operation();op.tick()
        XCTAssertEqual(f.factories,0);XCTAssertEqual(f.results,[.refused])
        let second=Fixture();second.onRoute={second.now=8};let late=second.operation();late.tick()
        XCTAssertEqual(second.factories,0);XCTAssertEqual(second.results,[.timedOut(mutationMayHaveOccurred:false)])
    }
    func testCancelInsideFactoryClosesReturnedSocketAndCannotSend() {
        let f=Fixture();let op=f.operation();f.onFactory={op.cancel()};op.tick();f.onFactory=nil
        XCTAssertTrue(f.transport.sent.isEmpty);XCTAssertEqual(f.transport.closes,1);XCTAssertEqual(f.results,[.cancelled(mutationMayHaveOccurred:false)])
    }
    func testPcpMapNonceCorrelationAndDeadlineReturnsKnownLateGrant() {
        let f=Fixture(), nonce=Data(0..<12)
        let op=f.operation(.pcpMap(nonce:nonce,internalPort:47830,externalPort:47830,lifetime:3600,externalAddress:nil));op.tick()
        var b=Data(repeating:0,count:24);b[0]=2;b[1]=129;b[6]=14;b[7]=16;b[11]=7
        b += nonce;b += Data([17,0,0,0,0xba,0xd6,0xc0,0xa9]);b += Data([0,0,0,0,0,0,0,0,0,0,255,255,203,0,113,7])
        var wrong=b;wrong[24] ^= 1;f.enqueue(wrong);op.tick();XCTAssertTrue(f.results.isEmpty)
        f.enqueue(b);f.now=8;op.tick()
        if case let .lateResponse(value,_)?=f.results.first { XCTAssertEqual(value.externalAddress,"203.0.113.7") } else { XCTFail("Known grant must survive timeout for cleanup") }
    }
    func testAnnounceIgnoredLifetimeAndBoundedUnknownOptions() {
        let f=Fixture();var packet=f.announce();packet[7]=99;packet[2]=255
        let gateway=Endpoint("192.0.2.1",5351)
        XCTAssertEqual(RouterMappingPackets.pcpAnnounceReply(packet+Data([128,0,0,0]),from:gateway,gateway:gateway)?.lifetime,0)
        XCTAssertNil(RouterMappingPackets.pcpAnnounceReply(packet+Data([128,0,0,4]),from:gateway,gateway:gateway))
        XCTAssertNil(RouterMappingPackets.pcpAnnounceReply(packet.dropLast(),from:gateway,gateway:gateway))
    }
}
