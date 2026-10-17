import Darwin
import Foundation

extension ProductTestPack {
    static func checkHeartbeat() -> Step {
        let name="Heartbeat wire round-trip + ping→pong echo"
        var count=0,failures:[String]=[]
        func require(_ condition:Bool,_ code:String) { count += 1;if !condition { failures.append(code) } }
        let ping=HeartbeatPayload.encode(.ping,tickMs:123456789)
        require(HeartbeatPayload.parse(ping)?.tickMs==123456789 && HeartbeatPayload.parse(ping)?.kind == .ping,"heartbeat.payload-roundtrip")
        require(ping==Data([0,21,205,91,7,0,0,0,0]),"heartbeat.payload-golden")
        require(HeartbeatPayload.parse(Data(ping.prefix(8)))==nil,"heartbeat.short-payload")
        var bad=ping;bad[0]=2
        require(HeartbeatPayload.parse(bad)==nil,"heartbeat.unknown-kind")
        let flagged=HeartbeatPayload.encode(.pong,tickMs:42,flags:1)
        require(HeartbeatPayload.parse(flagged)?.flags==1 && HeartbeatPayload.parse(flagged)?.kind == .pong,"heartbeat.optional-flags")
        require(HeartbeatTiming.pingInterval==1,"heartbeat.one-second-cadence")
        require(UInt64(HeartbeatTiming.pingInterval*2000)<=HeartbeatTiming.healthyWindowMs && HeartbeatTiming.healthyWindowMs<HeartbeatTiming.unreachableWindowMs,"heartbeat.windows-cover-pings")
        var timing=HeartbeatTiming();let address="fixture",sent:UInt64=100_000,pong:UInt64=100_024
        timing.sent(tickMs:sent,selected:[address])
        require(timing.health(for:address,nowTickMs:sent+1000).state == .pending,"heartbeat.never-pong-pending")
        require(timing.health(for:address,nowTickMs:sent+5001).state == .unreachable,"heartbeat.never-pong-unreachable")
        require(timing.health(for:address,nowTickMs:sent+1000).status=="ping pending","heartbeat.pending-summary")
        require(timing.health(for:address,nowTickMs:sent+10_000).status=="ping unreachable 10.0 s","heartbeat.never-pong-summary")
        require(!timing.receivedPong(from:address,echoTickMs:sent-1,nowTickMs:pong),"heartbeat.foreign-clock-refused")
        require(!timing.receivedPong(from:address,echoTickMs:sent,nowTickMs:sent-1),"heartbeat.future-echo-refused")
        require(!timing.receivedPong(from:address,echoTickMs:sent,nowTickMs:sent+30_001),"heartbeat.excess-roundtrip-refused")
        require(timing.receivedPong(from:address,echoTickMs:sent,nowTickMs:pong),"heartbeat.own-echo-accepted")
        for (age,state) in [(UInt64(1000),HeartbeatTiming.State.healthy),(2000,.healthy),(2001,.stale),(3000,.stale),(5000,.stale),(5001,.unreachable),(6000,.unreachable)] {
            require(timing.health(for:address,nowTickMs:pong+age).state==state,"heartbeat.window-"+String(age))
        }
        require(timing.health(for:address,nowTickMs:pong+1000).status=="ping 25 ms","heartbeat.healthy-rounded-summary")
        require(timing.health(for:address,nowTickMs:pong+3000).status=="ping stale 3.0 s","heartbeat.stale-summary")
        require(timing.health(for:address,nowTickMs:pong+6000).status=="ping unreachable 6.0 s","heartbeat.unreachable-summary")
        require(timing.health(for:address,nowTickMs:pong+3000).currentRTT==nil,"heartbeat.stale-not-current-latency")
        require(timing.health(for:address,nowTickMs:pong-1).state == .pending,"heartbeat.clock-regression")
        timing.forget(address)
        require(timing.health(for:address,nowTickMs:pong+10_000).state == .pending,"heartbeat.removed-peer-forgotten")
        var bounded=HeartbeatTiming()
        for tick in UInt64(1)...17 { bounded.sent(tickMs:tick) }
        require(!bounded.receivedPong(from:address,echoTickMs:1,nowTickMs:20) && bounded.receivedPong(from:address,echoTickMs:17,nowTickMs:20),"heartbeat.recent-sixteen-only")

        guard let raw=ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"] else {
            return .init(name:name,status:failures.isEmpty ? "UNVERIFIED" : "FAIL",assertions:count,failures:failures+["isolated-heartbeat-fixture-root-required"])
        }
        let base=URL(fileURLWithPath:raw);var attributes=stat()
        guard base.path==raw,base.resolvingSymlinksInPath().path==raw,
            raw != FileManager.default.homeDirectoryForCurrentUser.path,
            lstat(raw,&attributes)==0,attributes.st_mode&S_IFMT==S_IFDIR,
            attributes.st_uid==getuid(),attributes.st_mode&0o077==0 else {
            return .init(name:name,status:"FAIL",assertions:count+1,failures:failures+["heartbeat.fixture-root-refused"])
        }
        let root=base.appendingPathComponent("heartbeat-product-"+UUID().uuidString)
        var session:Session?,retired=false
        do {
            let peer=try UDP(port:0,loopback:true)
            let owner=try Session.isolatedAudioProductSession(peerPort:peer.boundPort,root:root);session=owner
            owner.start(password:"synthetic heartbeat",peerAddress:"",send:false,receive:false,plugins:false,name:"Heartbeat check")
            let ports=owner.testPorts,target=Endpoint("127.0.0.1",ports.audio),remote=Endpoint("127.0.0.1",peer.boundPort)
            require(ports.audio>0 && ports.discovery>0 && ports.bridge==0,"heartbeat.owned-bind")
            owner.testSelectResolvedDirectPeer(name:"Synthetic peer",endpoint:remote)
            var ownPing:Wire.Packet?
            let deadline=ProcessInfo.processInfo.systemUptime+1.5
            repeat {
                for _ in 0..<32 {
                    guard let (bytes,source)=peer.receive() else { break }
                    if source==target,let packet=Wire.parse(bytes),packet.kind == .heartbeat,HeartbeatPayload.parse(packet.payload)?.kind == .ping { ownPing=packet;break }
                }
                if ownPing != nil { break };Thread.sleep(forTimeInterval:0.0005)
            } while ProcessInfo.processInfo.systemUptime<deadline
            guard let ownPing,let beat=HeartbeatPayload.parse(ownPing.payload) else { throw ProtocolError.invalid("Fixture ping missing") }
            require(owner.testHeartbeatPeerStatus(address:remote.address,nowTickMs:beat.tickMs+1)?.contains("ping pending")==true,"heartbeat.actual-pending-status")
            require(peer.send(Wire.packet(.heartbeat,stream:ownPing.stream,sequence:ownPing.sequence,payload:HeartbeatPayload.encode(.pong,tickMs:beat.tickMs)),to:target),"heartbeat.actual-pong-send")
            let marker:UInt32=0x71000001
            require(peer.send(Wire.packet(.heartbeat,stream:0xffff,sequence:marker,payload:HeartbeatPayload.encode(.ping,tickMs:42000)),to:target),"heartbeat.actual-ping-send")
            var echo:Wire.Packet?
            let echoDeadline=ProcessInfo.processInfo.systemUptime+0.5
            repeat {
                for _ in 0..<32 {
                    guard let (bytes,source)=peer.receive() else { break }
                    if source==target,let packet=Wire.parse(bytes),packet.kind == .heartbeat,packet.sequence==marker { echo=packet;break }
                }
                if echo != nil { break };Thread.sleep(forTimeInterval:0.0005)
            } while ProcessInfo.processInfo.systemUptime<echoDeadline
            require(echo?.stream==0xffff && HeartbeatPayload.parse(echo?.payload ?? Data())?.kind == .pong && HeartbeatPayload.parse(echo?.payload ?? Data())?.tickMs==42000,"heartbeat.actual-source-endpoint-unchanged-tick")
            let now=UInt64(ProcessInfo.processInfo.systemUptime*1000)
            let healthy=owner.testHeartbeatPeerStatus(address:remote.address,nowTickMs:now) ?? ""
            require(healthy.contains("; ping ") && healthy.contains(" ms") && !healthy.contains("pending") && !healthy.contains("total latency"),"heartbeat.actual-quiet-visible-ping")
            require(owner.testHeartbeatPeerStatus(address:remote.address,nowTickMs:now+3000)?.contains("ping stale")==true,"heartbeat.actual-visible-stale")
            require(owner.testHeartbeatPeerStatus(address:remote.address,nowTickMs:now+6000)?.contains("ping unreachable")==true,"heartbeat.actual-visible-unreachable")
            require(owner.testProtocolObservation()?.streams==0,"heartbeat.no-audio-authority")
            retired=owner.finishIsolatedProductSession();require(retired && owner.testPorts.audio==0,"heartbeat.actual-retirement")
            if retired {
                let rebound=try [ports.audio,ports.discovery].map { try UDP(port:$0,loopback:true) }
                require(rebound.allSatisfy { $0.boundPort>0 },"heartbeat.actual-sockets-released")
            }
        } catch { require(false,"heartbeat.fixture-or-protocol-error") }
        if let session { retired=session.finishIsolatedProductSession();require(retired,"heartbeat.final-retirement") }
        session=nil
        if retired {
            do { try FileManager.default.removeItem(at:root);require(!FileManager.default.fileExists(atPath:root.path),"heartbeat.fixture-cleanup") }
            catch { require(false,"heartbeat.fixture-cleanup") }
        }
        return .init(name:name,status:failures.isEmpty ? "PASS" : "FAIL",assertions:count,failures:failures)
    }
}
