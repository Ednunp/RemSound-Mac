import Foundation
import XCTest
@testable import RemSoundCore

final class DirectedPeerDiscoveryTests: XCTestCase {
    func testNumericHintsDeduplicateOptionalPortsAndExcludeInvalidOrKnownServerAddresses() {
        let owner = DispatchQueue(label: "private numeric discovery hints")
        var queries: [String] = []
        let hints = DirectedPeerDiscovery(owner: owner, monitorNetwork: false, lookup: { host, _ in queries.append(host); return {} },
            isServer: { host, address in host.lowercased() == "server.invalid" || address == "192.0.2.2" || host == "192.0.2.2" })
        owner.sync {
            hints.start()
            hints.update(remembered: [" 192.0.2.1:54321 ", "192.0.2.1", "server.INVALID:12345", "192.0.2.2", "224.0.0.1", "255.255.255.255", "0.0.0.0", "invalid:port"], addresses: [], at: 100)
            hints.noteHeard("192.0.2.1", at: 100)
            hints.noteHeard("192.0.2.2", at: 100)
            hints.noteHeard("240.0.0.1", at: 100)
            XCTAssertEqual(hints.targets(at: 100), ["192.0.2.1"])
            XCTAssertTrue(queries.isEmpty)
            hints.stop()
        }
    }

    func testHostnameCacheDoesNotLookupEveryTickAndRefreshesAtDeadline() {
        let owner = DispatchQueue(label: "private discovery refresh")
        var clock: TimeInterval = 100
        var replies: [(String?) -> Void] = [], hosts: [String] = []
        let hints = DirectedPeerDiscovery(owner: owner, monitorNetwork: false, now: { clock }, lookup: { host, reply in
            hosts.append(host); replies.append(reply); return {}
        })
        owner.sync {
            hints.start()
            hints.update(remembered: [" Studio.invalid:12345 ", "studio.INVALID:54321"], addresses: [], at: clock)
            XCTAssertEqual(hosts, ["Studio.invalid"])
            XCTAssertTrue(hints.targets(at: clock).isEmpty)
            replies[0]("192.0.2.1"); replies[0]("192.0.2.9")
        }
        owner.sync {
            for _ in 0..<100 {
                hints.update(remembered: ["Studio.invalid"], addresses: [], at: clock)
                XCTAssertEqual(hints.targets(at: clock), ["192.0.2.1"])
            }
            XCTAssertEqual(hosts.count, 1)
            clock = 129; _ = hints.targets(at: clock); XCTAssertEqual(hosts.count, 1)
            clock = 130; _ = hints.targets(at: clock); XCTAssertEqual(hosts.count, 2)
            replies[1]("192.0.2.2")
        }
        owner.sync { XCTAssertEqual(hints.targets(at: clock), ["192.0.2.2"]); hints.stop() }
    }

    func testRemovedRestartedAndNetworkReplacedQueriesCannotDeliverStaleAddresses() {
        let owner = DispatchQueue(label: "private cancelled discovery hints")
        var replies: [(String?) -> Void] = [], cancelled = 0
        let hints = DirectedPeerDiscovery(owner: owner, monitorNetwork: false, now: { 100 }, lookup: { _, reply in
            replies.append(reply); return { cancelled += 1 }
        })
        owner.sync {
            hints.start(); hints.update(remembered: ["old.invalid"], addresses: [], at: 100)
            hints.update(remembered: ["new.invalid"], addresses: [], at: 100)
            XCTAssertEqual(cancelled, 1)
            replies[0]("192.0.2.1")
            hints.networkChanged(); XCTAssertEqual(cancelled, 2)
            replies[1]("192.0.2.2")
            hints.stop(); XCTAssertEqual(cancelled, 3)
            hints.start(); hints.update(remembered: ["current.invalid"], addresses: [], at: 100)
            replies[2]("192.0.2.3"); replies[3]("192.0.2.4")
        }
        owner.sync { XCTAssertEqual(hints.targets(at: 100), ["192.0.2.4"]); hints.stop() }
    }

    func testHintAndQueryBooksAreBoundedDuringRepeatedUpdatesAndCancellation() {
        let owner = DispatchQueue(label: "private bounded discovery DNS")
        var replies: [(String?) -> Void] = [], cancelled = 0
        let hints = DirectedPeerDiscovery(owner: owner, monitorNetwork: false, now: { 100 }, lookup: { _, reply in
            replies.append(reply); return { cancelled += 1 }
        })
        let names = (0..<200).map { "host\($0).invalid" }
        owner.sync {
            hints.start()
            for _ in 0..<100 { hints.update(remembered: names, addresses: [], at: 100) }
            XCTAssertEqual(replies.count, DirectedPeerDiscovery.maximumQueries)
            for reply in replies { reply("192.0.2.1") }
        }
        owner.sync {
            XCTAssertEqual(replies.count, DirectedPeerDiscovery.maximumQueries * 2)
            hints.stop()
            XCTAssertEqual(cancelled, DirectedPeerDiscovery.maximumQueries)
            for reply in replies { reply("192.0.2.9") }
        }
        owner.sync { XCTAssertTrue(hints.targets(at: 100).isEmpty) }
    }

    func testHeardSourcesAreCappedAndExpireIndependentlyOfPersistedHints() {
        let owner = DispatchQueue(label: "private heard-source bounds")
        let hints = DirectedPeerDiscovery(owner: owner, monitorNetwork: false)
        owner.sync {
            hints.start()
            hints.update(remembered: [], addresses: (0..<200).map { "198.51.100.\($0)" }, at: 100)
            for i in 0..<200 { hints.noteHeard("192.0.2.\(i)", at: 100) }
            XCTAssertEqual(hints.targets(at: 100).count, DirectedPeerDiscovery.maximumHints + DirectedPeerDiscovery.maximumHeardSources)
            XCTAssertEqual(hints.targets(at: 130).count, 128)
            XCTAssertEqual(hints.targets(at: 131).count, DirectedPeerDiscovery.maximumHints)
            hints.stop(); XCTAssertTrue(hints.targets(at: 131).isEmpty)
        }
    }

    func testDynamicServerClassificationExcludesCachedAndHeardAddressesWithoutAStorageWrite() {
        let owner = DispatchQueue(label: "private server hint exclusion")
        var server = false
        let hints = DirectedPeerDiscovery(owner: owner, monitorNetwork: false, isServer: { _, address in server && address == "192.0.2.1" })
        owner.sync {
            hints.start(); hints.update(remembered: [], addresses: ["192.0.2.1"], at: 100)
            hints.noteHeard("192.0.2.1", at: 100)
            XCTAssertEqual(hints.targets(at: 100), ["192.0.2.1"])
            server = true; XCTAssertTrue(hints.targets(at: 100).isEmpty)
            hints.stop()
        }
    }

    func testSynchronousFailedOrInvalidLookupsDeferDeliveryAndUseBoundedRetry() {
        let owner = DispatchQueue(label: "private immediate discovery lookup")
        var clock: TimeInterval = 100, count = 0
        let hints = DirectedPeerDiscovery(owner: owner, monitorNetwork: false, now: { clock }, lookup: { _, reply in
            count += 1; reply(count == 1 ? "224.0.0.1" : "127.0.0.1"); return {}
        })
        owner.sync {
            hints.start(); hints.update(remembered: ["host.invalid"], addresses: [], at: clock)
            XCTAssertTrue(hints.targets(at: clock).isEmpty)
        }
        owner.sync {
            XCTAssertTrue(hints.targets(at: clock).isEmpty); XCTAssertEqual(count, 1)
            clock = 130; _ = hints.targets(at: clock)
            XCTAssertTrue(hints.targets(at: clock).isEmpty)
        }
        owner.sync { XCTAssertEqual(hints.targets(at: clock), ["127.0.0.1"]); hints.stop() }
    }

    func testRetiredOwnerCancelsNativeBoundaryAndCannotAcceptLateCallback() {
        let owner = DispatchQueue(label: "private retired discovery owner")
        var reply: ((String?) -> Void)?, cancelled = 0
        var hints: DirectedPeerDiscovery? = DirectedPeerDiscovery(owner: owner, monitorNetwork: false, lookup: { _, callback in
            reply = callback; return { cancelled += 1 }
        })
        weak var retired = hints
        owner.sync {
            hints?.start(); hints?.update(remembered: ["host.invalid"], addresses: [], at: 100)
            hints = nil; XCTAssertNil(retired); XCTAssertEqual(cancelled, 1)
            reply?("192.0.2.1")
        }
        owner.sync {}
    }
}
