import Foundation
import Network
import XCTest
import RemSoundRuntime
@testable import RemSoundCore
final class WebNativeListenerTests:XCTestCase {
    private final class Child:WebNativeListener.Child {
        var isLoopback=true,state:((WebNativeTransport.State)->Void)?,read:((Data?,Bool,Bool)->Void)?,write:((Bool)->Void)?
        var starts=0,cancels=0,reads=0,writes=0,ready=true,inlineCancel=false,autoWrite=false,data=[Data]()
        func start(queue:DispatchQueue,state:@escaping (WebNativeTransport.State)->Void) {starts += 1;self.state=state;if ready {state(.ready)}}
        func receive(maximum:Int,completion:@escaping (Data?,Bool,Bool)->Void) {reads += 1;read=completion}
        func send(_ bytes:Data,completion:@escaping (Bool)->Void) {writes += 1;data.append(bytes);write=completion;if autoWrite {completion(true)}}
        func cancel() {cancels += 1;if inlineCancel {state?(.cancelled)}}
        func retire() {read?(nil,false,true);write?(false);state?(.cancelled)}
    }
    private final class Raw:WebNativeListener.Raw {
        var state:((WebNativeListener.State)->Void)?,accepted:((WebNativeListener.Child)->Bool)?,starts=0,cancels=0,grants=0,credit=false
        var startHook:(()->Void)?,cancelHook:(()->Void)?
        func start(queue:DispatchQueue,state:@escaping (WebNativeListener.State)->Void,accepted:@escaping (WebNativeListener.Child)->Bool) {starts += 1;self.state=state;self.accepted=accepted;startHook?();state(.ready(41000))}
        func grantOne() {XCTAssertFalse(credit,"Duplicate native credit");credit=true;grants += 1}
        func cancel() {cancels += 1;credit=false;cancelHook?()}
        func emit(_ child:Child)->Bool {guard credit else {return false};credit=false;return accepted?(child) ?? false}
    }
    private final class Fixture {
        let queue=DispatchQueue(label:"test.web.native.listener"),key=DispatchSpecificKey<Int>(),raw=Raw()
        var listener:WebRoom.Listener?,enabled=true,factories=0,offers=[WebRoom.Incoming](),children=[Child](),accept=true,factoryHook:(()->Void)?
        init() {queue.setSpecific(key:key,value:1)}
        func on(_ body:()->Void) {queue.sync(execute:body)}
        func drain() {for _ in 0..<24 {queue.sync {}}}
        func make(isolated:Bool=false) {on {listener=WebNativeListener.make(queue:queue,isolated:isolated,permitted:{[weak self] in self?.enabled ?? false},factory:{[self] gate in XCTAssertTrue(gate());factories += 1;factoryHook?();return raw})}}
        func start() {make();on {listener?.start(offer:{[weak self] value in guard let self else {return false};XCTAssertEqual(DispatchQueue.getSpecific(key:key),1);offers.append(value);return accept},failed:{})};drain()}
        @discardableResult func emit()->Child {let value=Child();children.append(value);on {XCTAssertTrue(raw.emit(value))};drain();return value}
        func cleanup() {on {listener?.close {};for child in children {child.retire()};raw.state?(.cancelled)};drain();on {for child in children {child.retire()};raw.state?(.cancelled);offers.removeAll();listener=nil};drain()}
    }
    func testOffAndIsolatedRefuseBeforeRawFactory() {
        for isolated in [false,true] {let f=Fixture();f.enabled=isolated;f.make(isolated:isolated);f.on {XCTAssertNil(f.listener);XCTAssertEqual(f.factories,0)};f.cleanup()}
    }
    func testOneCreditAtATimeAndTwelveOwnedChildrenBeforeMoreAcceptance() {
        let f=Fixture();defer {f.cleanup()};f.start();for _ in 0..<12 {_ = f.emit()};f.on {XCTAssertEqual(f.offers.count,12);XCTAssertFalse(f.raw.credit);XCTAssertEqual(f.raw.grants,12);XCTAssertFalse(f.raw.emit(Child()))}
    }
    func testRefusedIncomingStaysOwnedUntilExactCancellationAndReturnsOneCredit() {
        let f=Fixture();defer {f.cleanup()};f.accept=false;f.start();let value=f.emit()
        f.on {XCTAssertEqual(value.starts,1);XCTAssertEqual(value.cancels,1);XCTAssertEqual(f.raw.grants,2);value.retire()};f.drain();f.on {XCTAssertEqual(f.raw.grants,2)}
    }
    func testClosingUnstartedIncomingWaitsFinalChildAndListenerReceipts() {
        let f=Fixture();defer {f.cleanup()};f.start();let value=f.emit();var closed=0
        f.on {f.listener?.close {closed += 1}};f.drain();f.on {XCTAssertEqual(value.starts,1);XCTAssertEqual(value.cancels,1);f.raw.state?(.cancelled)};f.drain();f.on {XCTAssertEqual(closed,0);value.retire()};f.drain();f.on {XCTAssertEqual(closed,1)}
    }
    func testTransferredTransportCloseWaitsBothIOCallbacksAndNativeCancelled() {
        let f=Fixture();defer {f.cleanup()};f.start();let value=f.emit();var transport:WebConnection.Transport?,closed=0,received=0
        f.on {transport=f.offers.first?.transport(permitted:{true});transport?.read(maximum:4) {_ in received += 1};transport?.write(Data([1])) {_ in received += 1}};f.drain();f.on {XCTAssertEqual(value.reads,1);XCTAssertEqual(value.writes,1);f.listener?.close {closed += 1}};f.drain()
        f.on {value.state?(.cancelled);f.raw.state?(.cancelled);value.read?(nil,false,true)};f.drain();f.on {XCTAssertEqual(closed,0);value.write?(false)};f.drain();f.on {XCTAssertEqual(received,2);XCTAssertEqual(closed,1);transport=nil};f.drain()
    }
    func testTransferredResourceRetirementReplenishesOnlyOneCredit() {
        let f=Fixture();defer {f.cleanup()};f.start();for _ in 0..<12 {_ = f.emit()};var transport:WebConnection.Transport?
        f.on {transport=f.offers.first?.transport(permitted:{true});transport?.close {}};f.drain();f.on {f.children.first?.retire()};f.drain();f.on {XCTAssertEqual(f.raw.grants,13);XCTAssertTrue(f.raw.credit);f.children.first?.retire();transport=nil};f.drain();f.on {XCTAssertEqual(f.raw.grants,13)}
    }
    func testNonLoopbackAcceptedResourceNeverTransfersOrReadsButRetires() {
        let f=Fixture();defer {f.cleanup()};f.start();let value=Child();value.isLoopback=false;f.children.append(value)
        f.on {XCTAssertTrue(f.raw.emit(value))};f.drain();f.on {XCTAssertEqual(f.offers.count,0);XCTAssertEqual(value.starts,1);XCTAssertEqual(value.reads,0);XCTAssertEqual(value.cancels,1);value.retire()};f.drain()
    }
    func testLateFactoryDisableOwnsRawUntilCloseAndNeverGrants() {
        let f=Fixture();defer {f.cleanup()};f.factoryHook={f.enabled=false};f.make();var closed=0
        f.on {XCTAssertNotNil(f.listener);f.listener?.close {closed += 1}};f.drain();f.on {XCTAssertEqual(f.raw.starts,1);XCTAssertEqual(f.raw.grants,0);XCTAssertEqual(f.raw.cancels,1);XCTAssertEqual(closed,0);f.raw.state?(.cancelled)};f.drain();f.on {XCTAssertEqual(closed,1)}
    }
    func testLastListenerReleaseOwnsAcceptedChildrenUntilActualCleanup() {
        let f=Fixture();defer {f.cleanup()};f.start();let value=f.emit();f.on {f.listener=nil};f.drain();f.on {XCTAssertEqual(value.cancels,1);XCTAssertEqual(f.raw.cancels,1);value.retire();f.raw.state?(.cancelled)};f.drain()
    }
    private final class Timer:WebNativeListener.Timer {
        var pulse:(()->Void)?,starts=0,cancels=0,startHook:(()->Void)?
        func start(queue:DispatchQueue,pulse:@escaping ()->Void) {starts += 1;self.pulse=pulse;startHook?()}
        func cancel() {cancels += 1}
    }
    func testActiveSchedulerSurvivesFortyFiveSecondsAndStopsBeforeMoreClockCalls() {
        let queue=DispatchQueue(label:"test.web.active.schedule"),timer=Timer();var now=100.0,clocks=0,pulses=0,stop:(()->Void)?
        queue.sync {stop=WebNativeListener.activeSchedule(permitted:{true},clock:{clocks += 1;return now},factory:{timer})(queue,{pulses += 1})};for _ in 0..<8 {queue.sync {}}
        queue.sync {now=1000;timer.pulse?()};for _ in 0..<8 {queue.sync {}};queue.sync {XCTAssertEqual(pulses,1);XCTAssertEqual(timer.cancels,0);XCTAssertNotNil(stop);stop?();let count=clocks;timer.pulse?();XCTAssertEqual(clocks,count)};for _ in 0..<8 {queue.sync {}};queue.sync {XCTAssertEqual(pulses,1);XCTAssertEqual(timer.cancels,1);stop=nil}
    }
    func testSchedulerOffInvalidAndLateFactoryRefuseBeforeStart() {
        let queue=DispatchQueue(label:"test.web.active.guard")
        for invalid in [Double.nan,-1,Double.greatestFiniteMagnitude] {let timer=Timer();var factories=0;queue.sync {XCTAssertNil(WebNativeListener.activeSchedule(permitted:{true},clock:{invalid},factory:{factories += 1;return timer})(queue,{}));XCTAssertEqual(factories,0)}}
        let timer=Timer();var enabled=true;queue.sync {XCTAssertNil(WebNativeListener.activeSchedule(permitted:{enabled},clock:{100},factory:{enabled=false;return timer})(queue,{}));XCTAssertEqual(timer.starts,0);XCTAssertEqual(timer.cancels,1)}
    }
    func testSchedulerBackwardClockFinalPulseAndCancellationAreBounded() {
        let queue=DispatchQueue(label:"test.web.active.clock"),timer=Timer();var now=100.0,pulses=0,stop:(()->Void)?
        queue.sync {stop=WebNativeListener.activeSchedule(permitted:{true},clock:{now},factory:{timer})(queue,{pulses += 1});now=99;for _ in 0..<100 {timer.pulse?()}};for _ in 0..<10 {queue.sync {}};queue.sync {XCTAssertEqual(pulses,1);XCTAssertEqual(timer.cancels,1);stop?();stop=nil}
    }

    private func room(_ f:Fixture,_ now:@escaping ()->Double={100},_ timer:Timer?=nil)->WebRoom.Service {
        let credential=WebAuthentication.Credential.make(password:"synthetic",salt:Data(repeating:0,count:16),derive:{_,_ in Data(repeating:1,count:32)})!
        let room=WebRoom.Service(queue:f.queue,isolated:false,permitted:{f.enabled},listener:{gate in let listener=WebNativeListener.make(queue:f.queue,isolated:false,permitted:gate,factory:{_ in f.raw});f.listener=listener;return listener},clock:now,schedule:{_,_ in {}},peerSchedule:WebNativeListener.activeSchedule(permitted:{f.enabled},clock:now,factory:{timer ?? Timer()}),random:{Data(repeating:2,count:$0)},verify:{_,_ in true})
        f.on {XCTAssertTrue(room.start(configuration:{.init(credential:credential,page:Data("fixed".utf8),policy:.init(hosts:["example.test:47840"],origins:["https://example.test"]),source:"fixed")}))};f.drain();return room
    }
    private var head:Data {Data("GET /listen HTTP/1.1\r\nHost: example.test:47840\r\nOrigin: https://example.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n".utf8)}
    private var answer:Data {let bytes=Data("{\"response\":\"\(Data(repeating:1,count:32).base64EncodedString())\"}".utf8);return Data([0x81,0x80|UInt8(bytes.count),0,0,0,0])+bytes}
    func testActualMockNativeRoomPeerChainSurvivesAdmissionDriverLifetime() {
        let f=Fixture(),timer=Timer();var now=100.0;let room=room(f,{now},timer);defer {f.on {_ = room.shutdown()};f.cleanup()}
        let child=f.emit();child.autoWrite=true;f.on {child.read?(head,false,false)};f.drain();f.on {child.read?(answer,false,false)};f.drain()
        f.on {XCTAssertEqual(room.snapshot?.welcomed,1);XCTAssertEqual(child.reads,3);now=1000;timer.pulse?()};f.drain();f.on {XCTAssertEqual(room.snapshot?.welcomed,1);XCTAssertEqual(timer.cancels,0);XCTAssertGreaterThan(child.writes,3)}
        var stopped=0;f.on {_ = room.stop {stopped += 1}};f.drain();f.on {f.raw.state?(.cancelled);child.retire()};f.drain();f.on {XCTAssertEqual(stopped,1);XCTAssertEqual(timer.cancels,1)}
    }
    func testNativeFailureMakesRoomStopAndWaitForActualListenerReceipt() {
        let f=Fixture();let room=room(f);defer {f.on {_ = room.shutdown()};f.cleanup()}
        f.on {f.raw.state?(.failed)};f.drain();f.on {XCTAssertEqual(room.snapshot?.state,.stopping);f.raw.state?(.cancelled)};f.drain();f.on {XCTAssertEqual(room.snapshot?.state,.off)}
    }
    func testLateAcceptedCreditDuringCloseIsOwnedBeforeListenerReceipt() {
        let f=Fixture();defer {f.cleanup()};f.start();let child=Child();f.children.append(child);var stopped=0
        f.on {XCTAssertTrue(f.raw.emit(child));f.listener?.close {stopped += 1};f.raw.state?(.cancelled)};f.drain()
        f.on {XCTAssertEqual(f.offers.count,0);XCTAssertEqual(child.cancels,1);XCTAssertEqual(stopped,0);child.retire()};f.drain();f.on {XCTAssertEqual(stopped,1);XCTAssertEqual(f.raw.grants,1)}
    }
    func testNativeRuntimeConvenienceAndServiceRefuseIsolatedBeforeFactories() throws {
        let root=URL(fileURLWithPath:ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"]!).appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let runtime=try RuntimeConfiguration(options:LaunchOptions.parse(["--config-dir",root.path,"--headless","--silent"]))
        let queue=DispatchQueue(label:"test.web.native.isolated");var configs=0
        queue.sync {XCTAssertNil(WebNativeListener.native(queue:queue,runtime:runtime,port:WebNativeListener.defaultPort,permitted:{true}));let service=WebNativeListener.service(queue:queue,runtime:runtime,permitted:{true});XCTAssertFalse(service.start(configuration:{configs += 1;return nil}));_ = service.shutdown()};queue.sync {};XCTAssertEqual(configs,0)
    }
    func testActualOwnedNativeListenerRoomAuthenticationPeerAndShutdown() {
        let queue=DispatchQueue(label:"test.web.native.room.owned"),closed=expectation(description:"native room/listener/child retired"),clientClosed=expectation(description:"native room client retired")
        let credential=WebAuthentication.Credential.make(password:"synthetic",salt:Data(repeating:0,count:16),derive:{_,_ in Data(repeating:1,count:32)})!
        var client:NWConnection?,room:WebRoom.Service?,buffer=Data(),phase=0,stopping=false,seenPort:UInt16?
        let frames=WebSocketPackets.Reader(fromClient:false)
        queue.sync {
            room=WebRoom.Service(queue:queue,isolated:false,permitted:{true},listener:{gate in
                WebNativeListener.ownedLoopback(queue:queue,permitted:gate,bound:{port in
                    seenPort=port;XCTAssertNotEqual(port,WebNativeListener.defaultPort)
                    let connection=NWConnection(host:.ipv4(.loopback),port:NWEndpoint.Port(rawValue:port)!,using:.tcp);client=connection
                    connection.stateUpdateHandler={state in
                        switch state {
                        case .ready:
                            connection.send(content:self.head,completion:.contentProcessed {XCTAssertNil($0)})
                            func receive() {
                                connection.receive(minimumIncompleteLength:1,maximumLength:4096) {data,_,end,error in
                                    if stopping {return};XCTAssertNil(error);if let data {buffer.append(data)};XCTAssertLessThanOrEqual(buffer.count,16384)
                                    for _ in 0..<8 {
                                        if phase==0 {guard let split=buffer.range(of:Data("\r\n\r\n".utf8)) else {break};XCTAssertTrue(String(decoding:buffer.prefix(upTo:split.upperBound),as:UTF8.self).hasPrefix("HTTP/1.1 101 "));buffer=Data(buffer.suffix(from:split.upperBound));phase=1}
                                        guard !buffer.isEmpty else {break};let receipt=frames.feed(buffer);buffer=Data(buffer.dropFirst(receipt.consumedBytes));if receipt.event == .pending {break}
                                        if phase==1,case .text=receipt.event {phase=2;connection.send(content:self.answer+Data([0x89,0x81,0,0,0,0,7]),completion:.contentProcessed {XCTAssertNil($0)})}
                                        else if phase==2,case .text(let bytes)=receipt.event,let object=(try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any],object["type"] as? String=="welcome" {phase=3}
                                        else if phase==3,case .text(let bytes)=receipt.event,let object=(try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any],object["type"] as? String=="idle" {XCTAssertEqual(room?.peers?.first?.idle,true)}
                                        else if phase==3,case .pong(let bytes)=receipt.event {XCTAssertEqual(bytes,Data([7]));phase=4;stopping=true;XCTAssertEqual(room?.snapshot?.welcomed,1);_ = room?.stop {closed.fulfill();connection.cancel()};return}
                                        else {XCTFail("Unexpected native peer frame");return}
                                    }
                                    if !end {receive()}
                                }
                            };receive()
                        case .cancelled:clientClosed.fulfill()
                        case .failed(let error):XCTFail("Native peer client failed: \(error)");connection.cancel()
                        default:break
                        }
                    };connection.start(queue:queue)
                })
            },clock:{ProcessInfo.processInfo.systemUptime},schedule:WebNativeTransport.schedule(permitted:{true}),peerSchedule:WebNativeListener.nativeSchedule(permitted:{true}),random:{Data(repeating:2,count:$0)},verify:{_,_ in true})
            XCTAssertTrue(room?.start(configuration:{.init(credential:credential,page:Data("fixed".utf8),policy:.init(hosts:["example.test:47840"],origins:["https://example.test"]),source:"fixed")}) ?? false)
        }
        wait(for:[closed,clientClosed],timeout:5)
        queue.sync {_ = room?.shutdown();room=nil;client?.cancel();client?.stateUpdateHandler=nil;client=nil;XCTAssertEqual(phase,4);XCTAssertNotNil(seenPort)};queue.sync {}
    }

    func testDuplicateReadyDoesNotRepublishBindingAndChangedPortFailsClosed() {
        let f=Fixture();defer {f.cleanup()};var ports=[UInt16](),failures=0
        f.on {f.listener=WebNativeListener.make(queue:f.queue,isolated:false,permitted:{true},bound:{ports.append($0)},factory:{_ in f.raw});f.listener?.start(offer:{_ in false},failed:{failures += 1})};f.drain()
        f.on {f.raw.state?(.ready(41000))};f.drain();f.on {XCTAssertEqual(ports,[41000]);f.raw.state?(.ready(42000))};f.drain();f.on {XCTAssertEqual(ports,[41000]);XCTAssertEqual(failures,1);XCTAssertEqual(f.raw.cancels,1)}
    }
    func testSchedulerCancellationInsideClockWinsBeforeAnotherPulse() {
        let queue=DispatchQueue(label:"test.web.active.reentrant"),timer=Timer();var cancelInside=false,pulses=0,stop:(()->Void)?
        queue.sync {stop=WebNativeListener.activeSchedule(permitted:{true},clock:{if cancelInside {stop?()};return 100},factory:{timer})(queue,{pulses += 1});cancelInside=true;timer.pulse?()};for _ in 0..<10 {queue.sync {}}
        queue.sync {XCTAssertEqual(pulses,0);XCTAssertEqual(timer.cancels,1);stop=nil}
    }
    func testForeignAcceptedCallbackIsReservedBeforeOwnerMarshalling() {
        let f=Fixture();defer {f.cleanup()};f.start();let child=Child();f.children.append(child);var reply:((WebNativeListener.Child)->Bool)?
        f.on {f.raw.credit=false;reply=f.raw.accepted};let delivered=expectation(description:"foreign native offer returned"),callback=reply
        DispatchQueue.global().async {XCTAssertTrue(callback?(child) ?? false);delivered.fulfill()};wait(for:[delivered],timeout:2);f.drain();f.on {XCTAssertEqual(f.offers.count,1);XCTAssertEqual(child.starts,0)}
    }
    func testActualOwnedNativeListenerAnswersHalfClosedPageAndRetiresChild() {
        let queue=DispatchQueue(label:"test.web.native.page.owned"),closed=expectation(description:"native half-closed room retired"),clientClosed=expectation(description:"native half-closed client retired")
        let credential=WebAuthentication.Credential.make(password:"synthetic",salt:Data(repeating:0,count:16),derive:{_,_ in Data(repeating:1,count:32)})!
        var room:WebRoom.Service?,client:NWConnection?,buffer=Data(),finishing=false,trace=[String]()
        queue.sync {
            room=WebRoom.Service(queue:queue,isolated:false,permitted:{true},listener:{gate in WebNativeListener.ownedLoopback(queue:queue,permitted:gate,bound:{port in
                XCTAssertNotEqual(port,WebNativeListener.defaultPort);let connection=NWConnection(host:.ipv4(.loopback),port:NWEndpoint.Port(rawValue:port)!,using:.tcp);client=connection
                connection.stateUpdateHandler={state in switch state {
                case .ready:
                    trace.append("client-ready");connection.send(content:Data("GET / HTTP/1.1\r\nHost: example.test:47840\r\n\r\n".utf8),contentContext:.finalMessage,isComplete:true,completion:.contentProcessed {XCTAssertNil($0)})
                    func receive() {connection.receive(minimumIncompleteLength:1,maximumLength:4096) {data,_,end,error in
                        trace.append("read bytes=\(data?.count ?? 0) end=\(end) error=\(String(describing:error)) finishing=\(finishing)");if finishing {return};XCTAssertNil(error);if let data {buffer.append(data)};XCTAssertLessThanOrEqual(buffer.count,65536)
                        if end {finishing=true;trace.append("complete-eof");XCTAssertTrue(String(decoding:buffer,as:UTF8.self).hasPrefix("HTTP/1.1 200 "));XCTAssertTrue(buffer.suffix(5)==Data("fixed".utf8));_ = room?.stop {trace.append("room-retired");closed.fulfill();connection.cancel()}} else {receive()}
                    }};receive()
                case .cancelled:trace.append("client-cancelled");clientClosed.fulfill()
                case .failed(let error):trace.append("client-failed finishing=\(finishing)");if !finishing {XCTFail("Native page client failed before completed EOF: \(error)")};connection.cancel()
                default:break
                }};connection.start(queue:queue)
            })},clock:{ProcessInfo.processInfo.systemUptime},schedule:WebNativeTransport.schedule(permitted:{true}),peerSchedule:WebNativeListener.nativeSchedule(permitted:{true}))
            XCTAssertTrue(room?.start(configuration:{.init(credential:credential,page:Data("fixed".utf8),policy:.init(hosts:["example.test:47840"],origins:[]),source:"fixed")}) ?? false)
        }
        wait(for:[closed,clientClosed],timeout:5);queue.sync {_ = room?.shutdown();room=nil;client?.cancel();client?.stateUpdateHandler=nil;client=nil;XCTAssertTrue(finishing);print("OWNED_PAGE_TRACE \(trace)")};queue.sync {}
    }
}
