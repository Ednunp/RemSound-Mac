import Foundation
import XCTest
@testable import RemSoundCore

final class ServerAddressResolverTests: XCTestCase {
    func testReplacementStopAndDuplicateRepliesCannotReachLaterRequests() {
        let owner = DispatchQueue(label: "private server resolver replacement")
        var replies: [(String?) -> Void] = []
        var cancelled = 0
        var found: [Endpoint?] = []
        let resolver = ServerAddressResolver(owner: owner, lookup: { _, reply in
            replies.append(reply)
            return { cancelled += 1 }
        })
        owner.sync {
            resolver.start("first.invalid", port: 50001) { found.append($0) }
            resolver.start("second.invalid", port: 50002) { found.append($0) }
            XCTAssertEqual(cancelled, 1)
            XCTAssertEqual(replies.count, 2)
            if replies.count == 2 {
                replies[0]("192.0.2.1")
                replies[1]("192.0.2.2")
                replies[1]("192.0.2.3")
            }
        }
        owner.sync {
            XCTAssertEqual(found.count, 1)
            XCTAssertEqual(found.first ?? nil, Endpoint("192.0.2.2", 50002))
            resolver.start("third.invalid", port: 50003) { found.append($0) }
            resolver.stop()
            XCTAssertEqual(replies.count, 3)
            if replies.count == 3 { replies[2]("192.0.2.4") }
            XCTAssertEqual(cancelled, 2)
        }
        owner.sync { XCTAssertEqual(found.count, 1) }
    }

    func testSynchronousLookupDefersDeliveryAndFailureAllowsAnExplicitRetry() {
        let owner = DispatchQueue(label: "private server resolver immediate")
        var lookups = 0
        var found: [Endpoint?] = []
        let resolver = ServerAddressResolver(owner: owner, lookup: { _, reply in
            lookups += 1
            reply(lookups == 1 ? nil : "127.0.0.1")
            return {}
        })
        owner.sync {
            resolver.start("localhost", port: 54321) { found.append($0) }
            XCTAssertTrue(found.isEmpty)
        }
        owner.sync {
            XCTAssertEqual(found.count, 1)
            XCTAssertNil(found.first ?? nil)
            resolver.start("localhost", port: 54322) { found.append($0) }
        }
        owner.sync {
            XCTAssertEqual(lookups, 2)
            XCTAssertEqual(found.last ?? nil, Endpoint("127.0.0.1", 54322))
        }
    }

    func testNumericAddressesDoNotUseDNSAndCanBeCancelledBeforeDelivery() {
        let owner = DispatchQueue(label: "private numeric server resolver")
        var lookups = 0
        var found: [Endpoint?] = []
        let resolver = ServerAddressResolver(owner: owner, lookup: { _, _ in
            lookups += 1
            return {}
        })
        owner.sync {
            resolver.start("127.0.0.1", port: 50001) { found.append($0) }
            resolver.stop()
            resolver.start("127.0.0.2", port: 50002) { found.append($0) }
            XCTAssertTrue(found.isEmpty)
        }
        owner.sync {
            XCTAssertEqual(lookups, 0)
            XCTAssertEqual(found.count, 1)
            XCTAssertEqual(found.first ?? nil, Endpoint("127.0.0.2", 50002))
        }
    }

    func testInvalidInputsNeverStartQueriesAndInvalidAnswersAreRejected() {
        let owner = DispatchQueue(label: "private invalid server resolver")
        var lookups = 0
        var found: [Endpoint?] = []
        let resolver = ServerAddressResolver(owner: owner, lookup: { _, reply in
            lookups += 1
            reply("invalid reply")
            return {}
        })
        for host in ["", "has space.invalid", "bad\u{0}.invalid", String(repeating: "x", count: 254)] {
            owner.sync { resolver.start(host, port: 54321) { found.append($0) } }
            owner.sync { XCTAssertNil(found.last ?? nil) }
        }
        owner.sync { resolver.start("localhost", port: 0) { found.append($0) } }
        owner.sync {
            XCTAssertNil(found.last ?? nil)
            XCTAssertEqual(lookups, 0)
            resolver.start("localhost", port: 54321) { found.append($0) }
        }
        owner.sync {
            XCTAssertNil(found.last ?? nil)
            XCTAssertEqual(found.count, 6)
            XCTAssertEqual(lookups, 1)
        }
    }

    func testPendingQueryIsCancelledWhenOwnerRetires() {
        let owner = DispatchQueue(label: "private retired server resolver")
        var reply: ((String?) -> Void)?
        var cancelled = 0
        var resolver: ServerAddressResolver? = ServerAddressResolver(owner: owner, lookup: { _, completion in
            reply = completion
            return { cancelled += 1 }
        })
        weak var retired = resolver
        owner.sync {
            resolver?.start("pending.invalid", port: 54321) { _ in XCTFail("Retired owner received a result") }
            resolver = nil
            XCTAssertNil(retired)
            XCTAssertEqual(cancelled, 1)
            reply?("192.0.2.1")
        }
        owner.sync {}
    }
}
