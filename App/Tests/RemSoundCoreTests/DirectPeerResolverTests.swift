import Darwin
import Foundation
import XCTest
@testable import RemSoundCore

final class DirectPeerResolverTests: XCTestCase {
    func testSavedExplicitPortsResolveTheirHostsAndRoundTripWithoutDNSForNumericAddresses() {
        let owner = DispatchQueue(label: "private saved port restore")
        var queries: [(String, (String?) -> Void)] = []
        var found: [(String, Endpoint)] = []
        let resolver = DirectPeerResolver(owner: owner, monitorNetwork: false, lookup: { name, reply in
            queries.append((name, reply)); return {}
        })
        owner.sync {
            resolver.resolved = { found.append(($0, $1)) }
            resolver.start(["127.0.0.1:54321", " Studio.invalid:54322 "], port: 12345)
            XCTAssertEqual(queries.map { $0.0 }, ["Studio.invalid"])
            XCTAssertEqual(found.first?.0, "127.0.0.1:54321")
            XCTAssertEqual(found.first?.1, Endpoint("127.0.0.1", 54321))
            for query in queries { query.1("127.0.0.2") }
        }
        owner.sync {
            XCTAssertEqual(found.last?.0, "Studio.invalid:54322")
            XCTAssertEqual(found.last?.1, Endpoint("127.0.0.2", 54322))
            XCTAssertEqual(resolver.savedEntries(selectedAddresses: ["127.0.0.1", "127.0.0.2"]), ["127.0.0.1:54321", "Studio.invalid:54322"])
            resolver.stop()
        }
    }

    func testRecordedAddKeepsOriginalPortAndCancelsPendingSameNameLookup() {
        let owner = DispatchQueue(label: "private Add recording")
        var reply: ((String?) -> Void)?
        var cancellations = 0, resolved = 0
        let resolver = DirectPeerResolver(owner: owner, monitorNetwork: false, lookup: { _, completion in
            reply = completion; return { cancellations += 1 }
        })
        owner.sync {
            resolver.resolved = { _, _ in resolved += 1 }
            resolver.start(["Studio.invalid"], port: 12345)
            XCTAssertTrue(resolver.record(name: "STUDIO.invalid", address: "127.0.0.2"))
            XCTAssertTrue(resolver.record(name: "Studio.invalid:54321", address: "127.0.0.2"))
            XCTAssertEqual(cancellations, 1)
            reply?("127.0.0.1")
        }
        owner.sync {
            XCTAssertEqual(resolved, 0)
            XCTAssertEqual(resolver.savedEntries(selectedAddresses: ["127.0.0.2"]), ["Studio.invalid", "Studio.invalid:54321"])
            resolver.stop()
        }
    }
    func testRecordedAddIsBoundedAndRedirectedWithoutReselectingUntickedPeers() {
        let owner = DispatchQueue(label: "private bounded Add recording")
        let resolver = DirectPeerResolver(owner: owner, monitorNetwork: false, lookup: { _, _ in {} })
        owner.sync {
            resolver.start([], port: 12345)
            for i in 0..<DirectPeerResolver.maximumEntries {
                XCTAssertTrue(resolver.record(name: "host\(i)", address: "127.0.0.1"))
            }
            XCTAssertFalse(resolver.record(name: "overflow", address: "127.0.0.2"))
            XCTAssertFalse(resolver.record(name: " ", address: "127.0.0.2"))
            resolver.redirect(address: "127.0.0.1", to: "127.0.0.2")
            XCTAssertEqual(resolver.savedEntries(selectedAddresses: ["127.0.0.2"]).count, DirectPeerResolver.maximumEntries)
            XCTAssertTrue(resolver.savedEntries(selectedAddresses: []).isEmpty)
            resolver.stop()
        }
    }

    func testRedirectRetainsTypedNameAndDoesNotReselectAfterUnticking() {
        let owner = DispatchQueue(label: "private redirect fixture")
        var completion: ((String?) -> Void)?
        let resolver = DirectPeerResolver(owner: owner, monitorNetwork: false, lookup: { _, reply in
            completion = reply
            return {}
        })
        owner.sync {
            resolver.start(["Studio"], port: 54321)
            completion?("192.0.2.1")
        }
        owner.sync {
            resolver.redirect(address: "192.0.2.1", to: "192.0.2.2")
            XCTAssertEqual(resolver.savedEntries(selectedAddresses: ["192.0.2.2"]), ["Studio"])
            XCTAssertEqual(resolver.savedEntries(selectedAddresses: []), [])
            resolver.networkChanged()
            XCTAssertEqual(resolver.savedEntries(selectedAddresses: []), [])
            resolver.stop()
        }
    }

    func testRetryTimingNetworkChangeNamesAndDeselection() {
        let owner = DispatchQueue(label: "private resolver test")
        var clock: TimeInterval = 100
        var queries: [(String, (String?) -> Void)] = []
        var failures = 0
        let resolver = DirectPeerResolver(owner: owner, monitorNetwork: false,
            now: { clock }, lookup: { name, reply in queries.append((name, reply)); return {} })
        owner.sync {
            resolver.unavailable = { _ in failures += 1 }
            resolver.start([" Missing.local ", "missing.LOCAL", "127.0.0.1"], port: 54321)
            XCTAssertEqual(queries.count, 1)
            XCTAssertEqual(resolver.savedEntries(selectedAddresses: ["127.0.0.1"]),
                ["Missing.local", "127.0.0.1"])
            queries[0].1(nil)
        }
        owner.sync {
            XCTAssertEqual(failures, 1)
            clock = 129
            resolver.tick()
            XCTAssertEqual(queries.count, 1)
            clock = 130
            resolver.tick()
            XCTAssertEqual(queries.count, 2)
            queries[1].1(nil)
        }
        owner.sync {
            XCTAssertEqual(failures, 1)
            resolver.networkChanged()
            XCTAssertEqual(queries.count, 3)
            queries[2].1("192.0.2.4")
        }
        owner.sync {
            XCTAssertEqual(resolver.savedEntries(selectedAddresses: ["192.0.2.4", "127.0.0.1"]),
                ["Missing.local", "127.0.0.1"])
            XCTAssertEqual(resolver.savedEntries(selectedAddresses: ["192.0.2.8"]), ["192.0.2.8"])
            clock = 200
            resolver.networkChanged()
            resolver.tick()
            XCTAssertEqual(queries.count, 3, "Resolved but deselected peers must not be selected again")
            resolver.stop()
        }
    }

    func testBoundedQueriesCancellationAndStaleCompletionAcrossRestart() {
        let owner = DispatchQueue(label: "private resolver churn")
        var queries: [(String, (String?) -> Void)] = []
        var cancelled = 0, resolved = 0
        let resolver = DirectPeerResolver(owner: owner, monitorNetwork: false, lookup: { name, reply in
            queries.append((name, reply))
            return { cancelled += 1 }
        })
        owner.sync {
            resolver.resolved = { _, _ in resolved += 1 }
            resolver.start((0..<200).map { "host\($0).invalid" }, port: 54321)
            XCTAssertEqual(queries.count, DirectPeerResolver.maximumQueries)
            XCTAssertEqual(resolver.savedEntries(selectedAddresses: []).count, DirectPeerResolver.maximumEntries)
            resolver.networkChanged()
            XCTAssertEqual(queries.count, DirectPeerResolver.maximumQueries)
            resolver.stop()
            XCTAssertEqual(cancelled, DirectPeerResolver.maximumQueries)
            resolver.start(["new.invalid"], port: 54321)
            for query in queries.prefix(DirectPeerResolver.maximumQueries) { query.1("192.0.2.1") }
        }
        owner.sync {
            XCTAssertEqual(resolved, 0)
            XCTAssertEqual(resolver.savedEntries(selectedAddresses: []), ["new.invalid"])
            resolver.stop()
            XCTAssertEqual(cancelled, DirectPeerResolver.maximumQueries + 1)
        }
    }

    func testSynchronousLookupCompletionIsDeliveredOnOwnerWithoutBlockingIt() {
        let owner = DispatchQueue(label: "private resolver immediate completion")
        var found: Endpoint?
        let resolver = DirectPeerResolver(owner: owner, monitorNetwork: false, lookup: { _, reply in
            reply("127.0.0.1")
            return {}
        })
        owner.sync {
            resolver.resolved = { _, endpoint in found = endpoint }
            resolver.start(["localhost"], port: 54321)
            XCTAssertNil(found)
        }
        owner.sync {
            XCTAssertEqual(found, Endpoint("127.0.0.1", 54321))
            resolver.stop()
        }
    }

    func testNativeLocalhostLookupAndCancelledChurnReleaseQueries() {
        let found = expectation(description: "native localhost DNS")
        let cancel = DNSAddressLookup.start("localhost") { address in
            XCTAssertEqual(address, "127.0.0.1")
            found.fulfill()
        }
        wait(for: [found], timeout: DNSAddressLookup.timeout + 2)
        cancel()
        let before = openDescriptorCount()
        for _ in 0..<100 {
            let cancel = DNSAddressLookup.start("remsound-cancel.invalid") { _ in
                XCTFail("Cancelled lookup must not report")
            }
            cancel()
        }
        // The final query's completion fences the same serial native query queue.
        let drained = expectation(description: "native cancellations drained")
        let finalCancel = DNSAddressLookup.start("localhost") { _ in drained.fulfill() }
        wait(for: [drained], timeout: DNSAddressLookup.timeout + 2)
        finalCancel()
        XCTAssertLessThanOrEqual(openDescriptorCount(), before + 1,
            "Cancelled native queries must close their DNS sockets")
    }

    func testNativeDeadlineClosesAnUnansweredQuery() {
        let expired = expectation(description: "native query deadline")
        let started = ProcessInfo.processInfo.systemUptime
        let cancel = DNSAddressLookup.start("remsound-\(UUID().uuidString).local", timeout: 0.05) { address in
            XCTAssertNil(address)
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
            expired.fulfill()
        }
        wait(for: [expired], timeout: 1.5)
        cancel()
    }

    private func openDescriptorCount() -> Int {
        (0..<min(4096, getdtablesize())).filter { fcntl($0, F_GETFD) >= 0 }.count
    }
}
