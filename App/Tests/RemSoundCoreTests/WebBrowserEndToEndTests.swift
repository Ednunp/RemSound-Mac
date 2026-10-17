import AudioSupport
import CommonCrypto
import CryptoKit
import Darwin
import Foundation
import Network
import RemSoundRuntime
import XCTest
@testable import RemSoundCore

final class WebBrowserEndToEndTests:XCTestCase {
    final class Client {
        let queue=DispatchQueue(label:"test.browser.e2e.client"),connection:NWConnection,closed=XCTestExpectation(description:"owned browser client cancelled")
        let upgrading:Bool
        private var header=Data(),body=Data(),messages=[[String:Any]](),audio=[Data](),reader=WebSocketPackets.Reader(fromClient:false)
        private var pongs=[Data]()
        private var headDone=false,ended=false,cancelled=false,errors=[String](),status=""
        struct Snapshot {let status:String,body:Data,messages:[[String:Any]],audio:[Data],ended:Bool,errors:[String],pongs:[Data]}
        var snapshot:Snapshot {queue.sync{.init(status:status,body:body,messages:messages,audio:audio,ended:ended,errors:errors,pongs:pongs)}}
        init(port:UInt16,upgrade:Bool) {
            upgrading=upgrade;connection=NWConnection(host:.ipv4(.loopback),port:NWEndpoint.Port(rawValue:port)!,using:.tcp)
            connection.stateUpdateHandler={ [weak self] state in
                guard let self else {return}
                switch state {
                case .ready:
                    let authority="127.0.0.1:\(port)"
                    let request=upgrade ? "GET /listen HTTP/1.1\r\nHost: \(authority)\r\nOrigin: http://\(authority)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n" : "GET / HTTP/1.1\r\nHost: \(authority)\r\n\r\n"
                    self.connection.send(content:Data(request.utf8),completion:.contentProcessed{[weak self] error in if let error {self?.errors.append(String(describing:error))}})
                    self.read()
                case .failed(let error):self.errors.append(String(describing:error));self.connection.cancel()
                case .cancelled:if !self.cancelled {self.cancelled=true;self.closed.fulfill()}
                default:break
                }
            }
            connection.start(queue:queue)
        }
        private func read() {
            connection.receive(minimumIncompleteLength:1,maximumLength:8192) { [weak self] data,_,end,error in
                guard let self else {return}
                if let data {self.consume(data)}
                if let error {self.errors.append(String(describing:error))}
                if end || error != nil {self.ended=true} else {self.read()}
            }
        }
        private func consume(_ bytes:Data) {
            var input=bytes
            if !headDone {
                guard header.count+input.count<=65536 else {errors.append("HTTP fixture cap");connection.cancel();return}
                header.append(input)
                guard let split=header.range(of:Data("\r\n\r\n".utf8)) else {return}
                status=String(decoding:header.prefix(upTo:split.lowerBound),as:UTF8.self).components(separatedBy:"\r\n")[0]
                input=Data(header.suffix(from:split.upperBound));header=Data();headDone=true
            }
            if !upgrading {guard body.count+input.count<=65536 else {errors.append("Page fixture cap");connection.cancel();return};body.append(input);return}
            var turns=0
            while !input.isEmpty {
                turns += 1;guard turns<=64 else {errors.append("Frame fixture cap");connection.cancel();return}
                let result=reader.feed(input)
                guard result.consumedBytes>0,result.consumedBytes<=input.count else {errors.append("Invalid fixture frame progress");connection.cancel();return}
                input=Data(input.dropFirst(result.consumedBytes))
                switch result.event {
                case .text(let raw):
                    guard messages.count<64,let object=(try? JSONSerialization.jsonObject(with:raw)) as? [String:Any] else {errors.append("Text fixture cap");connection.cancel();return}
                    messages.append(object)
                case .binary(let value):guard audio.count<32 else {errors.append("Audio fixture cap");connection.cancel();return};audio.append(value)
                case .ping(let payload):sendFrame(10,payload)
                case .pong(let payload):guard pongs.count<8 else {errors.append("Pong fixture cap");connection.cancel();return};pongs.append(payload)
                case .close:ended=true
                case .protocolError:errors.append("Invalid server frame");connection.cancel();return
                default:break
                }
            }
        }
        private func sendFrame(_ opcode:UInt8,_ payload:Data) {
            guard payload.count<65536 else {errors.append("Client fixture message cap");return}
            var frame=Data([0x80|opcode])
            if payload.count<126 {frame.append(0x80|UInt8(payload.count))} else {frame.append(contentsOf:[0xfe,UInt8(payload.count>>8),UInt8(payload.count&255)])}
            let mask:[UInt8]=[0x19,0x27,0x35,0x43];frame.append(contentsOf:mask)
            frame.append(contentsOf:payload.enumerated().map{$0.element ^ mask[$0.offset&3]})
            connection.send(content:frame,completion:.contentProcessed{[weak self] error in if let error {self?.errors.append(String(describing:error))}})
        }
        func send(_ object:[String:Any]) throws {let bytes=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]);queue.async{self.sendFrame(1,bytes)}}
        func ping(_ bytes:Data){queue.async{self.sendFrame(9,bytes)}}
        func cancel(){queue.async{self.connection.cancel()}}
        func releaseCallbacks(){queue.sync{connection.stateUpdateHandler=nil}}
    }
    final class Fixture {
        let queue=DispatchQueue(label:"test.browser.e2e.facade"),peer:RemSoundCore.UDP,session:Session,runtime:RuntimeConfiguration,root:URL,port:UInt16
        var service:BrowserListenerService?,clients=[Client](),binding:SessionNetworkBinding?
        static let password="Browser fixture Pāss 🎵"
        init() throws {
            root=URL(fileURLWithPath:try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])).appendingPathComponent("e2e-config-"+UUID().uuidString)
            runtime=try RuntimeConfiguration(options:LaunchOptions.parse(["--config-dir",root.path,"--headless","--silent"]))
            peer=try RemSoundCore.UDP(port:0,loopback:true);session=Session(testPeerPort:peer.boundPort)
            let fd=Darwin.socket(AF_INET,SOCK_STREAM,0);guard fd>=0 else {throw POSIXError(.EIO)};defer{Darwin.close(fd)}
            var address=sockaddr_in();address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);address.sin_family=sa_family_t(AF_INET);address.sin_addr.s_addr=inet_addr("127.0.0.1")
            let result=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}}
            guard result==0 else {throw POSIXError(.EADDRINUSE)}
            var length=socklen_t(MemoryLayout<sockaddr_in>.size)
            guard withUnsafeMutablePointer(to:&address,{$0.withMemoryRebound(to:sockaddr.self,capacity:1){getsockname(fd,$0,&length)}})==0 else {throw POSIXError(.EIO)}
            port=UInt16(bigEndian:address.sin_port);XCTAssertNotEqual(port,0);XCTAssertNotEqual(port,WebNativeListener.defaultPort)
        }
        func start() throws {
            let started=XCTestExpectation(description:"owned Session running"),prepared=XCTestExpectation(description:"browser prepared"),configured=XCTestExpectation(description:"actual native browser and worker attached")
            session.start(password:"Separate audio fixture password",peerAddress:"",send:true,receive:false,plugins:false,name:"Fixture",sendPacketSize:.small,networkCompletion:{self.binding=$0;started.fulfill()})
            XCTAssertEqual(XCTWaiter.wait(for:[started],timeout:3),.completed);let binding=try XCTUnwrap(binding)
            XCTAssertEqual(session.testWebBoundAddresses(),["127.0.0.1","127.0.0.1"])
            var deps=WebBrowserDependencies.native(runtime,session)
            deps.listenerPort=port
            deps.admissionSchedule={WebNativeTransport.schedule(permitted:$0)};deps.peerSchedule={WebNativeListener.nativeSchedule(permitted:$0)}
            deps.listener={ [self] queue,gate,bound in WebNativeListener.ownedLoopback(queue:queue,port:port,permitted:gate,bound:{actual in XCTAssertEqual(actual,self.port);bound(actual)})}
            service=BrowserListenerService(queue:queue,isolated:false,dependencies:deps);let service=try XCTUnwrap(service),request=UUID()
            XCTAssertTrue(service.prepareStart(request){XCTAssertTrue($0);prepared.fulfill()});XCTAssertEqual(XCTWaiter.wait(for:[prepared],timeout:2),.completed)
            XCTAssertTrue(service.activate(request,binding:binding,options:.init(enabled:true,autoStart:true),password:Self.password){result in XCTAssertEqual(result,.listening(port:self.port));configured.fulfill()})
            XCTAssertEqual(XCTWaiter.wait(for:[configured],timeout:3),.completed);XCTAssertEqual(service.status.boundPort,port)
        }
        func startStopped() throws -> Bool {
            XCTAssertEqual(session.testPorts.audio,0);XCTAssertEqual(session.testPorts.bridge,0)
            var deps=WebBrowserDependencies.native(runtime,session)
            deps.listenerPort=port
            deps.admissionSchedule={WebNativeTransport.schedule(permitted:$0)};deps.peerSchedule={WebNativeListener.nativeSchedule(permitted:$0)}
            deps.listener={ [self] queue,gate,bound in WebNativeListener.ownedLoopback(queue:queue,port:port,permitted:gate,bound:bound) }
            service=BrowserListenerService(queue:queue,isolated:false,dependencies:deps)
            let service=try XCTUnwrap(service),request=UUID(),prepared=XCTestExpectation(description:"stopped listener prepare")
            XCTAssertTrue(service.prepareStart(request){XCTAssertTrue($0);prepared.fulfill()})
            XCTAssertEqual(XCTWaiter.wait(for:[prepared],timeout:2),.completed)
            let configured=XCTestExpectation(description:"actual stopped native bind")
            let accepted=service.activateStopped(request,options:.init(enabled:true,autoStart:true),password:Self.password){result in
                XCTAssertEqual(result,.listening(port:self.port));configured.fulfill()
            }
            XCTAssertTrue(accepted,"Stopped browser listening must not require Session.start or a fabricated worker.")
            guard accepted else {return false}
            XCTAssertEqual(XCTWaiter.wait(for:[configured],timeout:3),.completed)
            XCTAssertEqual(service.status.state,.listening);XCTAssertFalse(service.status.sourceAttached)
            XCTAssertEqual(service.status.boundPort,port);XCTAssertEqual(session.testPorts.audio,0)
            return service.status.state == .listening
        }
        func client(upgrade:Bool=true)->Client {let client=Client(port:port,upgrade:upgrade);clients.append(client);return client}
        func cleanup() {
            if let service {let closed=XCTestExpectation(description:"full source Room and native callbacks retired");XCTAssertTrue(service.shutdown{closed.fulfill()});XCTAssertEqual(XCTWaiter.wait(for:[closed],timeout:3),.completed);XCTAssertEqual(service.status.state,.closed)}
            for client in clients {client.cancel()};if !clients.isEmpty {XCTAssertEqual(XCTWaiter.wait(for:clients.map(\.closed),timeout:3),.completed)}
            for client in clients {client.releaseCallbacks()};clients.removeAll();service=nil
            let done=XCTestExpectation(description:"Session sockets and timers closed");session.shutdown{done.fulfill()};XCTAssertEqual(XCTWaiter.wait(for:[done],timeout:3),.completed)
            XCTAssertEqual(session.testPorts.audio,0);XCTAssertEqual(session.testPorts.discovery,0);XCTAssertEqual(session.testPorts.bridge,0)
            try? FileManager.default.removeItem(at:root)
        }
    }
    func until(_ condition:()->Bool,file:StaticString=#filePath,line:UInt=#line) {
        let limit=ProcessInfo.processInfo.systemUptime+3
        while !condition(),ProcessInfo.processInfo.systemUptime<limit {RunLoop.current.run(until:Date().addingTimeInterval(0.001))}
        XCTAssertTrue(condition(),file:file,line:line)
    }
    // Construct the existing lower Core services directly in an isolated fixture.
    // Production facade policy remains unchanged; its full stop is tested separately.
    private final class SourceContinuity {
        let fixture:Fixture
        var room:WebRoom.Service!,handoff:WebAudioHandoff.Service!,producer:WebAudioHandoff.Producer?
        var listenerFactories=0,sourceFactories=0
        init(_ fixture:Fixture) throws {
            self.fixture=fixture
            let credential=try XCTUnwrap(WebAuthentication.Credential.make(password:Fixture.password,salt:Data(repeating:0x24,count:16)))
            let port=fixture.port,authority="127.0.0.1:\(port)"
            room=WebRoom.Service(queue:fixture.queue,isolated:false,permitted:{true},listener:{ [weak self] gate in
                guard let self else {return nil};self.listenerFactories += 1
                return WebNativeListener.ownedLoopback(queue:fixture.queue,port:port,permitted:gate)
            },clock:{ProcessInfo.processInfo.systemUptime},schedule:WebNativeTransport.schedule(permitted:{true}),peerSchedule:WebNativeListener.nativeSchedule(permitted:{true}))
            handoff=WebAudioHandoff.Service(queue:fixture.queue,isolated:false,permitted:{true},factory:{[weak self] _,gate in
                guard let self else {return nil};self.sourceFactories += 1;return WebAudioHandoff.roomSink(self.room,permitted:gate)
            })
            fixture.queue.sync {
                var policy=WebAdmission.Policy(hosts:[authority],origins:["http://"+authority]);policy.autoStart=true
                XCTAssertTrue(room.start{.init(credential:credential,page:WebListenerPage.load()!,policy:policy,source:"Owned continuity fixture")})
            }
        }
        func startWorker() throws -> SessionNetworkBinding {
            let done=XCTestExpectation(description:"genuine owned Session start")
            var value:SessionNetworkBinding?
            fixture.session.start(password:"Separate audio fixture password",peerAddress:"",send:true,receive:false,plugins:false,name:"Fixture",sendPacketSize:.small,networkCompletion:{value=$0;done.fulfill()})
            XCTAssertEqual(XCTWaiter.wait(for:[done],timeout:3),.completed)
            return try XCTUnwrap(value)
        }
        @discardableResult func attach(_ binding:SessionNetworkBinding,expected:Bool=true) throws -> WebAudioHandoff.Producer {
            let opened=XCTestExpectation(description:"actual Room source factory returned"),installed=XCTestExpectation(description:"actual Session worker attachment returned")
            var next:WebAudioHandoff.Producer?
            fixture.queue.sync {XCTAssertTrue(handoff.open(.init(request:UUID(),network:binding)){next=$0;opened.fulfill()})}
            XCTAssertEqual(XCTWaiter.wait(for:[opened],timeout:3),.completed)
            let value=try XCTUnwrap(next);producer=value
            XCTAssertTrue(fixture.session.attachWebAudio(value){applied in XCTAssertEqual(applied,expected);installed.fulfill()})
            XCTAssertEqual(XCTWaiter.wait(for:[installed],timeout:3),.completed)
            return value
        }
        func detachAndStopWorker() {
            fixture.session.revokeWebAudio()
            let detached=XCTestExpectation(description:"raw source factory/consume/close retired independently of Room")
            XCTAssertTrue(handoff.stop{detached.fulfill()})
            XCTAssertEqual(XCTWaiter.wait(for:[detached],timeout:3),.completed)
            fixture.session.stop()
            let stopped=XCTestExpectation(description:"actual stopped worker and sockets observed")
            XCTAssertTrue(fixture.session.observeWebNetworkBinding{value in XCTAssertNil(value);stopped.fulfill()})
            XCTAssertEqual(XCTWaiter.wait(for:[stopped],timeout:3),.completed)
            XCTAssertEqual(fixture.session.testPorts.audio,0);XCTAssertEqual(fixture.session.testPorts.bridge,0)
            fixture.queue.sync {XCTAssertNil(handoff.snapshot?.binding);XCTAssertEqual(room.snapshot?.state,.running);XCTAssertEqual(room.snapshot?.welcomed,1)}
        }
        var reports:[WebPeer.Report] {fixture.queue.sync{room.peers?.compactMap(\.report) ?? []}}
        var epoch:UUID? {fixture.queue.sync{room.audioGeneration}}
        func cleanup() {
            guard room != nil else {return}
            fixture.session.revokeWebAudio()
            let source=XCTestExpectation(description:"continuity source permanently closed"),closed=XCTestExpectation(description:"same Room and every native IO/callback permanently closed")
            XCTAssertTrue(handoff.shutdown{source.fulfill()});XCTAssertTrue(room.shutdown{closed.fulfill()})
            XCTAssertEqual(XCTWaiter.wait(for:[source,closed],timeout:3),.completed)
            fixture.queue.sync {XCTAssertEqual(room.snapshot?.state,.closed);XCTAssertNil(handoff.snapshot?.binding)}
            producer=nil;handoff=nil;room=nil
        }
    }
    func testSameAuthenticatedRoomSurvivesActualSourceRetirementAndNewestWorkerReattachment() throws {
        let f=try Fixture();defer{f.cleanup()};let lower=try SourceContinuity(f);defer{lower.cleanup()}
        let first=try lower.startWorker(),old=try lower.attach(first),client=f.client()
        _=try authenticate(client,codec:"pcm16");welcomed(client)
        f.session.testCapture(samples(frames:1920));until{client.snapshot.audio.count==8}
        let epoch=try XCTUnwrap(lower.epoch)
        lower.detachAndStopWorker()
        XCTAssertFalse(old.isActive);XCTAssertFalse(old.offer(samples(frames:240),lane:.wasapi))
        XCTAssertNotEqual(epoch,lower.epoch)
        f.queue.sync {XCTAssertFalse(lower.room.feed(samples(frames:240),lane:.wasapi,generation:epoch))}
        var stoppedReport=report();stoppedReport["outMs"]=11
        try client.send(stoppedReport);client.ping(Data([0x24,0x60]))
        until{lower.reports.first?.outMs==11 && client.snapshot.pongs==[Data([0x24,0x60])]}
        XCTAssertFalse(client.snapshot.ended);XCTAssertEqual(client.snapshot.audio.count,8)
        let newest=try lower.startWorker();XCTAssertNotEqual(newest,first)
        let stale=try lower.attach(first,expected:false)
        XCTAssertFalse(stale.isActive)
        let staleRetired=XCTestExpectation(description:"refused stale source retired before replacement")
        XCTAssertTrue(lower.handoff.stop{staleRetired.fulfill()});XCTAssertEqual(XCTWaiter.wait(for:[staleRetired],timeout:3),.completed)
        _=try lower.attach(newest)
        f.session.testCapture(samples(frames:1920,left:0.125,right:-0.25));until{client.snapshot.audio.count==16}
        let after=client.snapshot.audio.suffix(8).compactMap{WebAudioPackets.parse($0,codec:.pcm16)}
        XCTAssertEqual(after.count,8)
        for packet in after {XCTAssertEqual(packet.payload,Data((0..<240).flatMap{_ in [UInt8(0),16,0,224]}))}
        try client.send(report());client.ping(Data([0x24,0x61]))
        until{lower.reports.first?.outMs==10 && client.snapshot.pongs.count==2}
        XCTAssertEqual(client.snapshot.messages.filter{$0["type"] as? String == "challenge"}.count,1)
        XCTAssertEqual(client.snapshot.messages.filter{$0["type"] as? String == "welcome"}.count,1)
        XCTAssertEqual(lower.listenerFactories,1);XCTAssertEqual(lower.sourceFactories,3)
        XCTAssertFalse(client.snapshot.ended);XCTAssertTrue(client.snapshot.errors.isEmpty)
        lower.cleanup();until{client.snapshot.ended}
        XCTAssertEqual(lower.listenerFactories,1)
    }
    func testFullFacadeStopRetiresAuthenticatedClientRatherThanOnlyAudio() throws {
        let f=try Fixture();defer{f.cleanup()};try f.start();let client=f.client()
        _=try authenticate(client,codec:"pcm16");welcomed(client)
        f.session.testCapture(samples(frames:1920));until{client.snapshot.audio.count==8}
        let service=try XCTUnwrap(f.service),retired=XCTestExpectation(description:"current full stop boundary")
        XCTAssertTrue(service.stop{retired.fulfill()});XCTAssertEqual(XCTWaiter.wait(for:[retired],timeout:3),.completed)
        until{client.snapshot.ended}
        XCTAssertTrue(client.snapshot.ended);XCTAssertEqual(service.status.state,.off)
    }
    func testFacadeAudioTransitionPreservesClientAndReattachesOnlyNewestWorker() throws {
        let f=try Fixture();defer{f.cleanup()};try f.start();let service=try XCTUnwrap(f.service),client=f.client()
        _=try authenticate(client,codec:"pcm16");welcomed(client)
        f.session.testCapture(samples(frames:1920));until{client.snapshot.audio.count==8}
        let request=UUID(),detached=XCTestExpectation(description:"facade source-only retirement")
        XCTAssertTrue(service.prepareAudioTransition(request){XCTAssertTrue($0);detached.fulfill()})
        XCTAssertEqual(XCTWaiter.wait(for:[detached],timeout:3),.completed)
        XCTAssertEqual(service.status.state,.listening,"Audio-only retirement must retain the actual native Room.")
        guard service.status.state == .listening else {return}
        XCTAssertFalse(service.status.sourceAttached)
        f.session.stop();let stopped=XCTestExpectation(description:"actual stopped worker")
        XCTAssertTrue(f.session.observeWebNetworkBinding{XCTAssertNil($0);stopped.fulfill()});XCTAssertEqual(XCTWaiter.wait(for:[stopped],timeout:3),.completed)
        try client.send(report());client.ping(Data([0x24,0x70]));until{service.testPeerReports().count==1 && client.snapshot.pongs.count==1}
        XCTAssertFalse(client.snapshot.ended)
        let startRequest=UUID(),prepared=XCTestExpectation(description:"same listener prepared for a new audio Start")
        XCTAssertTrue(service.prepareAudioTransition(startRequest){XCTAssertTrue($0);prepared.fulfill()});XCTAssertEqual(XCTWaiter.wait(for:[prepared],timeout:3),.completed)
        let started=XCTestExpectation(description:"new genuine worker/socket")
        f.session.start(password:"Separate audio fixture password",peerAddress:"",send:true,receive:false,plugins:false,name:"Fixture",sendPacketSize:.small,networkCompletion:{f.binding=$0;started.fulfill()})
        XCTAssertEqual(XCTWaiter.wait(for:[started],timeout:3),.completed)
        let bound=try XCTUnwrap(f.binding),attached=XCTestExpectation(description:"facade genuine new worker accepted")
        XCTAssertFalse(service.attachAudio(request,binding:bound){_ in XCTFail("Obsolete request cannot acquire a source callback.")})
        XCTAssertTrue(service.attachAudio(startRequest,binding:bound){XCTAssertTrue($0);attached.fulfill()});XCTAssertEqual(XCTWaiter.wait(for:[attached],timeout:3),.completed)
        XCTAssertTrue(service.status.sourceAttached)
        f.session.testCapture(samples(frames:1920,left:0.125,right:-0.25));until{client.snapshot.audio.count==16}
        for raw in client.snapshot.audio.suffix(8) {let packet=try XCTUnwrap(WebAudioPackets.parse(raw,codec:.pcm16));XCTAssertEqual(packet.payload,Data((0..<240).flatMap{_ in [UInt8(0),16,0,224]}))}
        XCTAssertEqual(client.snapshot.messages.filter{$0["type"] as? String == "challenge"}.count,1);XCTAssertEqual(client.snapshot.messages.filter{$0["type"] as? String == "welcome"}.count,1)
        XCTAssertFalse(client.snapshot.ended);XCTAssertTrue(client.snapshot.errors.isEmpty)
    }
    func testStoppedListenerAuthenticatesServesPageAndConsumesReportWithoutAudioWorker() throws {
        let f=try Fixture();defer{f.cleanup()};guard try f.startStopped() else {return}
        let page=f.client(upgrade:false);until{page.snapshot.ended};XCTAssertEqual(page.snapshot.body,WebListenerPage.load())
        let client=f.client();_=try authenticate(client,codec:"pcm16");welcomed(client)
        try client.send(report());until{f.service?.testPeerReports().isEmpty == false}
        XCTAssertTrue(client.snapshot.audio.isEmpty);XCTAssertEqual(f.session.testPorts.audio,0);XCTAssertFalse(f.service?.status.sourceAttached ?? true)
    }
    func testStoppedListenerRetiresBeforeSameServiceAcceptsActualRunningAudioAttachment() throws {
        let f=try Fixture();defer{f.cleanup()};guard try f.startStopped() else {return}
        let service=try XCTUnwrap(f.service),oldClient=f.client();_=try authenticate(oldClient,codec:"pcm16");welcomed(oldClient)
        let request=UUID(),prepared=XCTestExpectation(description:"old stopped Room fully retired")
        XCTAssertTrue(service.prepareStart(request){XCTAssertTrue($0);prepared.fulfill()})
        XCTAssertEqual(XCTWaiter.wait(for:[prepared],timeout:3),.completed);until{oldClient.snapshot.ended}
        let started=XCTestExpectation(description:"actual running Session socket")
        f.session.start(password:"Separate audio fixture password",peerAddress:"",send:true,receive:false,plugins:false,name:"Fixture",sendPacketSize:.small,networkCompletion:{f.binding=$0;started.fulfill()})
        XCTAssertEqual(XCTWaiter.wait(for:[started],timeout:3),.completed);let binding=try XCTUnwrap(f.binding)
        let attached=XCTestExpectation(description:"actual native bind and Session audio attachment")
        XCTAssertTrue(service.activate(request,binding:binding,options:.init(enabled:true,autoStart:true),password:Fixture.password){result in XCTAssertEqual(result,.listening(port:f.port));attached.fulfill()})
        XCTAssertEqual(XCTWaiter.wait(for:[attached],timeout:3),.completed);XCTAssertTrue(service === f.service);XCTAssertTrue(service.status.sourceAttached)
        let client=f.client();_=try authenticate(client,codec:"pcm16");welcomed(client);f.session.testCapture(samples(frames:1920))
        until{client.snapshot.audio.count>=8};XCTAssertEqual(client.snapshot.audio.compactMap{WebAudioPackets.parse($0,codec:.pcm16)}.count,8)
    }
    func testStoppedListenerWrongPasswordNeverWelcomesOrConstructsSessionSockets() throws {
        let f=try Fixture();defer{f.cleanup()};guard try f.startStopped() else {return}
        let client=f.client();_=try authenticate(client,codec:"pcm16",password:"Wrong synthetic browser password")
        until{client.snapshot.ended}
        XCTAssertFalse(client.snapshot.messages.contains{$0["type"] as? String == "welcome"})
        XCTAssertTrue(client.snapshot.audio.isEmpty);XCTAssertEqual(f.session.testPorts.audio,0)
    }
    func testServedPageUsesActualOwnedLoopbackAuthority() throws {
        let f=try Fixture();defer{f.cleanup()};try f.start();let client=f.client(upgrade:false)
        until{client.snapshot.ended};let result=client.snapshot
        XCTAssertEqual(result.status,"HTTP/1.1 200 OK");XCTAssertEqual(result.body,try XCTUnwrap(WebListenerPage.load()))
        try result.body.write(to:recordRoot().appendingPathComponent("served-page.html"))
    }

    private func recordRoot() throws -> URL {
        let url=URL(fileURLWithPath:try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])).appendingPathComponent("web-e2e-records",isDirectory:true)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true);return url
    }
    private func proof(password:String,challenge:[String:Any]) throws -> String {
        let salt=try XCTUnwrap(Data(base64Encoded:try XCTUnwrap(challenge["salt"] as? String)))
        let nonce=try XCTUnwrap(Data(base64Encoded:try XCTUnwrap(challenge["nonce"] as? String)))
        let rounds=try XCTUnwrap(challenge["iterations"] as? Int);XCTAssertEqual(rounds,150000);XCTAssertEqual(salt.count,16);XCTAssertEqual(nonce.count,32)
        let passwordBytes=Array(password.utf8);var key=[UInt8](repeating:0,count:32)
        let status=passwordBytes.withUnsafeBytes { password in salt.withUnsafeBytes { salt in key.withUnsafeMutableBytes { key in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),password.bindMemory(to:CChar.self).baseAddress,password.count,salt.bindMemory(to:UInt8.self).baseAddress,salt.count,CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),UInt32(rounds),key.bindMemory(to:UInt8.self).baseAddress,key.count)
        } } }
        XCTAssertEqual(status,Int32(kCCSuccess))
        return Data(HMAC<SHA256>.authenticationCode(for:nonce,using:SymmetricKey(data:Data(key)))).base64EncodedString()
    }
    private func authenticate(_ client:Client,codec:String,password:String=Fixture.password) throws -> [String:Any] {
        until{client.snapshot.messages.contains{$0["type"] as? String=="challenge"} || client.snapshot.ended}
        let challenge=try XCTUnwrap(client.snapshot.messages.first{$0["type"] as? String=="challenge"})
        XCTAssertEqual(client.snapshot.status,"HTTP/1.1 101 Switching Protocols");XCTAssertEqual(challenge["autoStart"] as? Bool,true)
        let response=try proof(password:password,challenge:challenge)
        try client.send(["type":"auth","response":response,"codec":codec])
        return ["password":password,"challenge":challenge,"response":response,"codec":codec]
    }
    private func welcomed(_ client:Client) {
        until{client.snapshot.messages.contains{$0["type"] as? String=="welcome"} || client.snapshot.ended}
        let welcome=client.snapshot.messages.first{$0["type"] as? String=="welcome"}
        XCTAssertNotNil(welcome);XCTAssertEqual(welcome?["frameMs"] as? Int,5);XCTAssertEqual(welcome?["autoStart"] as? Bool,true)
    }
    private func samples(frames:Int,left:Float=0.25,right:Float = -0.5)->[Float] {(0..<frames).flatMap{_ in [left,right]}}
    private func save(_ value:[String:Any],name:String) throws {
        let bytes=try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]);XCTAssertLessThan(bytes.count,65536);try bytes.write(to:recordRoot().appendingPathComponent(name+".json"))
    }
    private func report()->[String:Any] {
        ["type":"report","streams":[["id":1,"depthMs":40,"targetMs":40,"longestWaitMs":7,"gaps":0,"skips":0],["id":0,"depthMs":40,"targetMs":40,"longestWaitMs":9,"gaps":0,"skips":0]],"outMs":10,"rate":48000,"reconnects":0]
    }
    func testActualSessionPCMInputPluginAudioAndReportReachAuthenticatedClient() throws {
        let f=try Fixture();defer{f.cleanup()};try f.start();let client=f.client()
        var record=try authenticate(client,codec:"pcm16");welcomed(client)
        f.session.testCapture(samples(frames:1920));until{client.snapshot.audio.count>=8}
        var pid=Data();pid.put(UInt32(12345));let endpoint=Endpoint("127.0.0.1",f.peer.boundPort)
        f.session.testWebBridgePacket(Bridge.encode(.hello,instance:17,payload:pid),from:endpoint)
        var plugin=Data();for sample in samples(frames:1920,left:0.125,right:-0.25) {plugin.put(sample.bitPattern)}
        f.session.testWebBridgePacket(Bridge.encode(.trackAudio,instance:17,payload:plugin),from:endpoint);until{client.snapshot.audio.count>=16}
        let packets=client.snapshot.audio.compactMap{WebAudioPackets.parse($0,codec:.pcm16)}
        XCTAssertEqual(packets.count,16);XCTAssertEqual(packets.filter{$0.stream==1}.map(\.sequence),Array(0..<8).map(UInt32.init));XCTAssertEqual(packets.filter{$0.stream==0}.map(\.sequence),Array(0..<8).map(UInt32.init))
        for packet in packets {
            let pair:[UInt8]=packet.stream==1 ? [0,32,0,192]:[0,16,0,224]
            XCTAssertEqual(packet.payload,Data((0..<240).flatMap{_ in pair}))
        }
        let sent=report();try client.send(sent)
        let service=try XCTUnwrap(f.service);until{service.testPeerReports().count==1}
        let received=try XCTUnwrap(service.testPeerReports().first)
        XCTAssertEqual(received.rate,48000);XCTAssertEqual(received.outMs,10);XCTAssertEqual(received.reconnects,0);XCTAssertEqual(received.streams.map(\.id),[1,0]);XCTAssertEqual(received.streams.map(\.longestWaitMs),[7,9])
        record["audio"]=client.snapshot.audio.map{$0.base64EncodedString()};record["report"]=sent;try save(record,name:"pcm-worker-and-report")
        XCTAssertTrue(client.snapshot.errors.isEmpty)
    }
    func testActualNativeOpusEncoderProducesDecodableClientFrames() throws {
        let f=try Fixture();defer{f.cleanup()};try f.start();let client=f.client()
        var record=try authenticate(client,codec:"opus");welcomed(client)
        f.session.testCapture(samples(frames:1920));until{client.snapshot.audio.count>=8}
        let packets=client.snapshot.audio.compactMap{WebAudioPackets.parse($0,codec:.opus)}
        XCTAssertEqual(packets.count,8);XCTAssertEqual(packets.map(\.stream),Array(repeating:1,count:8));XCTAssertEqual(packets.map(\.sequence),Array(0..<8).map(UInt32.init))
        guard let decoder=rs_opus_decoder(2) else {return XCTFail("Actual Opus decoder unavailable")};defer{rs_opus_destroy(decoder)}
        var decoded=[Float]();for packet in packets {
            var output=[Float](repeating:0,count:480)
            let frames=packet.payload.withUnsafeBytes{bytes in output.withUnsafeMutableBufferPointer{rs_opus_decode(decoder,bytes.bindMemory(to:UInt8.self).baseAddress,Int32(packet.payload.count),$0.baseAddress,240)}}
            XCTAssertEqual(frames,240);XCTAssertTrue(output.allSatisfy(\.isFinite));decoded += output
        }
        XCTAssertGreaterThan(decoded.map{abs($0)}.max() ?? 0,0.005)
        record["audio"]=client.snapshot.audio.map{$0.base64EncodedString()};try save(record,name:"opus-worker")
        XCTAssertTrue(client.snapshot.errors.isEmpty)
    }
    func testWrongPasswordIsRefusedWithoutWelcomeAudioOrClientReport() throws {
        let f=try Fixture();defer{f.cleanup()};try f.start();let client=f.client()
        var record=try authenticate(client,codec:"pcm16",password:"Deliberately wrong fixture password")
        until{client.snapshot.messages.contains{$0["type"] as? String=="refused"} || client.snapshot.ended}
        XCTAssertTrue(client.snapshot.messages.contains{$0["type"] as? String=="refused"});XCTAssertFalse(client.snapshot.messages.contains{$0["type"] as? String=="welcome"})
        f.session.testCapture(samples(frames:1920));XCTAssertTrue(client.snapshot.audio.isEmpty)
        XCTAssertTrue(try XCTUnwrap(f.service).testPeerReports().isEmpty)
        record["messages"]=client.snapshot.messages;record["audio"]=client.snapshot.audio.map{$0.base64EncodedString()};try save(record,name:"wrong-password")
    }
}
