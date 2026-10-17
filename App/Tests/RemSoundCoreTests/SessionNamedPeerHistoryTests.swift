import Foundation
import XCTest
import RemSoundRuntime
@testable import RemSoundCore

final class SessionNamedPeerHistoryTests: XCTestCase {
    func testActualRenamePersistsMachineHistoryWithoutTreatingEveryPeerAsNamed() throws {
        let listener=try UDP(port:0,loopback:true)
        let session=Session(testPeerPort:listener.boundPort);defer{session.shutdown()}
        let ready=expectation(description:"owned Session ready")
        session.onChange={value in if value.running { session.onChange=nil;ready.fulfill() }}
        session.start(password:"private history fixture",peerAddress:"",send:false,receive:false,plugins:false,name:"history fixture")
        wait(for:[ready],timeout:3)
        session.testSelectResolvedDirectPeer(name:"Studio.invalid",endpoint:Endpoint("127.0.0.1",listener.boundPort))
        let root=try XCTUnwrap(session.testPeerHistoryReportRoot())
        XCTAssertNil(try SettingsStore(file:root.appendingPathComponent("settings.plist")).data(forKey:"namedPeerHistory"))
        session.setPeerAlias(address:"127.0.0.1",alias:"My studio")
        _=session.testPorts
        XCTAssertNotNil(try SettingsStore(file:root.appendingPathComponent("settings.plist")).data(forKey:"namedPeerHistory"))
    }
    func testOnlyCurrentAuthenticatedSelectedPeerUpdatesNamedAddressAndStopFlushes() throws {
        let listener=try UDP(port:0,loopback:true),session=Session(testPeerPort:listener.boundPort)
        defer{session.shutdown();withExtendedLifetime(listener){}}
        let ready=expectation(description:"owned history worker")
        session.start(password:"private history fixture",peerAddress:"",send:false,receive:false,plugins:false,name:"history fixture",completion:{_ in ready.fulfill()})
        wait(for:[ready],timeout:3)
        let old=Endpoint("127.0.0.1",listener.boundPort),fresh=Endpoint("127.0.0.2",listener.boundPort)
        session.testSelectResolvedDirectPeer(name:"Studio",endpoint:old)
        session.setPeerAlias(address:old.address,alias:"My room");_=session.testPorts
        let root=try XCTUnwrap(session.testPeerHistoryReportRoot())
        session.testSelectResolvedDirectPeer(name:"Studio",endpoint:fresh)
        let wrong=try Credentials(password:"wrong fixture"),key=try Credentials(password:"private history fixture"),id=UUID(),now=Int64(Date().timeIntervalSince1970)
        session.testPeerPacket(try wrong.tick(id:id,now:now,sequence:1),from:fresh)
        XCTAssertEqual(try RuntimeConfiguration.namedPeersForListing(root:root).first?.lastAddress,old.address)
        session.testPeerPacket(try key.tick(id:id,now:now,sequence:2),from:fresh)
        XCTAssertEqual(try RuntimeConfiguration.namedPeersForListing(root:root).first?.lastAddress,fresh.address)
        session.setPeerAlias(address:fresh.address,alias:"");_=session.testPorts
        XCTAssertTrue(try RuntimeConfiguration.namedPeersForListing(root:root).isEmpty)
        session.testPeerPacket(try key.tick(id:id,now:now,sequence:3),from:fresh)
        XCTAssertTrue(try RuntimeConfiguration.namedPeersForListing(root:root).isEmpty)
        session.shutdown();XCTAssertEqual(session.testPorts.audio,0)
    }

    func testActualStopFlushesDeferredHealthyTimestampAfterNativeRetirement() throws {
        let listener=try UDP(port:0,loopback:true),session=Session(testPeerPort:listener.boundPort)
        defer { session.shutdown();withExtendedLifetime(listener){} }
        let ready=expectation(description:"owned history stop worker")
        session.start(password:"private stop fixture",peerAddress:"",send:false,receive:false,plugins:false,name:"stop fixture",completion:{_ in ready.fulfill()})
        wait(for:[ready],timeout:3)
        let endpoint=Endpoint("127.0.0.1",listener.boundPort)
        session.testSelectResolvedDirectPeer(name:"Studio",endpoint:endpoint)
        session.setPeerAlias(address:endpoint.address,alias:"My room");_=session.testPorts
        let root=try XCTUnwrap(session.testPeerHistoryReportRoot()),file=root.appendingPathComponent("settings.plist")
        let before=try Data(contentsOf:file),date=try XCTUnwrap(RuntimeConfiguration.namedPeersForListing(root:root).first?.lastSeen)
        let key=try Credentials(password:"private stop fixture")
        session.testPeerPacket(try key.tick(id:UUID(),now:Int64(Date().timeIntervalSince1970),sequence:1),from:endpoint)
        XCTAssertEqual(try Data(contentsOf:file),before)
        session.shutdown();XCTAssertEqual(session.testPorts.audio,0)
        let updated=try XCTUnwrap(RuntimeConfiguration.namedPeersForListing(root:root).first?.lastSeen)
        XCTAssertGreaterThan(updated,date)
    }

    func testGlobalNameFollowsMachineAcrossProfileAliasesAndManagementUpdatesLivePeer() throws {
        let listener=try UDP(port:0,loopback:true),session=Session(testPeerPort:listener.boundPort)
        defer { session.shutdown();withExtendedLifetime(listener){} }
        let ready=expectation(description:"owned named worker")
        session.start(password:"named fixture",peerAddress:"",send:false,receive:false,plugins:false,name:"local",peerAliases:["127.0.0.1":"Profile alias"],completion:{_ in ready.fulfill()})
        wait(for:[ready],timeout:3)
        let endpoint=Endpoint("127.0.0.1",listener.boundPort)
        session.testSelectResolvedDirectPeer(name:"Studio",endpoint:endpoint)
        session.setPeerAlias(address:endpoint.address,alias:"Global room");_=session.testPorts
        let row=try XCTUnwrap(session.namedPeerRecords?.first)
        XCTAssertTrue(session.renameNamedPeer(row,friendlyName:"Renamed room"))
        XCTAssertFalse(session.renameNamedPeer(row,friendlyName:"Stale"))
        XCTAssertEqual(session.testDirectPeerViews().first?.name,"Renamed room")
        session.shutdown()
        let again=expectation(description:"second profile worker")
        session.start(password:"named fixture",peerAddress:"",send:false,receive:false,plugins:false,name:"local",peerAliases:["127.0.0.1":"Different profile alias"],completion:{_ in again.fulfill()})
        wait(for:[again],timeout:3)
        session.testSelectResolvedDirectPeer(name:"STUDIO",endpoint:endpoint)
        XCTAssertEqual(session.testDirectPeerViews().first?.name,"Renamed room")
        XCTAssertTrue(session.forgetNamedPeers(try XCTUnwrap(session.namedPeerRecords)))
        XCTAssertEqual(session.testDirectPeerViews().first?.name,"STUDIO")
        XCTAssertTrue(try XCTUnwrap(session.namedPeerRecords).isEmpty)
    }

    func testFailedGlobalSaveDoesNotChangeActualLiveNameOrProfileAliases() throws {
        let listener=try UDP(port:0,loopback:true),session=Session(testPeerPort:listener.boundPort)
        defer { session.shutdown();withExtendedLifetime(listener){} }
        let ready=expectation(description:"owned name failure worker")
        session.start(password:"named fixture",peerAddress:"",send:false,receive:false,plugins:false,name:"local",peerAliases:["127.0.0.1":"Profile alias"],completion:{_ in ready.fulfill()})
        wait(for:[ready],timeout:3)
        session.testSelectResolvedDirectPeer(name:"Studio",endpoint:Endpoint("127.0.0.1",listener.boundPort))
        session.setPeerAlias(address:"127.0.0.1",alias:"Before");_=session.testPorts
        let root=try XCTUnwrap(session.testPeerHistoryReportRoot()),file=root.appendingPathComponent("settings.plist")
        let bytes=try Data(contentsOf:file)
        try FileManager.default.removeItem(at:file);try FileManager.default.createDirectory(at:file,withIntermediateDirectories:false)
        session.setPeerAlias(address:"127.0.0.1",alias:"After");_=session.testPorts
        XCTAssertEqual(session.testDirectPeerViews().first?.name,"Before")
        XCTAssertEqual(session.namedPeerRecords?.first?.friendlyName,"Before")
        XCTAssertFalse(session.forgetNamedPeers(try XCTUnwrap(session.namedPeerRecords)))
        XCTAssertEqual(session.testDirectPeerViews().first?.name,"Before")
        try FileManager.default.removeItem(at:file);try bytes.write(to:file)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    func testOneGlobalRenamePropagatesToBothCurrentMachineAddressesAndRejectsStaleModalName() throws {
        let listener=try UDP(port:0,loopback:true),session=Session(testPeerPort:listener.boundPort)
        defer { session.shutdown();withExtendedLifetime(listener){} }
        let ready=expectation(description:"owned paired name worker")
        session.start(password:"named fixture",peerAddress:"",send:false,receive:false,plugins:false,name:"local",completion:{_ in ready.fulfill()})
        wait(for:[ready],timeout:3)
        for address in ["127.0.0.1","127.0.0.2"] {session.testSelectResolvedDirectPeer(name:"Studio",endpoint:Endpoint(address,listener.boundPort))}
        session.setPeerAlias(address:"127.0.0.1",alias:"Together");_=session.testPorts
        XCTAssertEqual(session.testDirectPeerViews().map(\.name),["Together","Together"])
        session.setPeerAlias(address:"127.0.0.1",alias:"Stale",expectedDisplayName:"Studio");_=session.testPorts
        XCTAssertEqual(session.testDirectPeerViews().map(\.name),["Together","Together"])
        XCTAssertEqual(session.namedPeerRecords?.count,1)
    }

}
