import Foundation
import XCTest
import RemSoundJam
@testable import RemSoundApp

final class ServerReleaseLookupTests: XCTestCase {
    private final class Fetch {
        private let lock = NSLock()
        var started: (() -> Void)?
        private var replies: [(Data?) -> Void] = []
        private var cancelled = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return replies.count }
        var cancels: Int { lock.lock(); defer { lock.unlock() }; return cancelled }
        func start(_ reply: @escaping (Data?) -> Void) -> () -> Void {
            lock.lock(); replies.append(reply); let notify = started; lock.unlock(); notify?()
            return { self.lock.lock(); self.cancelled += 1; self.lock.unlock() }
        }
        func complete(_ index: Int = 0, _ data: Data?) {
            lock.lock(); let reply = replies.indices.contains(index) ? replies[index] : nil; lock.unlock(); reply?(data)
        }
    }
    private let release = Data("[{\"tag_name\":\"server-v2.18\",\"draft\":false,\"prerelease\":false},{\"tag_name\":\"v99\",\"draft\":false,\"prerelease\":false}]".utf8)
    func testIsolationRefusesBeforeNativeFactory() {
        XCTAssertEqual(ServerVersionCheck.releaseListURL.path, "/repos/Ednunp/RemSound/releases")
        XCTAssertEqual(ServerVersionCheck.releaseListURL.host, "api.github.com")
        let fetch = Fetch(), done = expectation(description: "isolated unavailable release")
        let lookup = ServerReleaseLookup(permitted: { false }, fetch: fetch.start)
        defer { lookup.shutdown() }
        _ = lookup.latest { value in XCTAssertNil(value); done.fulfill() }
        wait(for: [done], timeout: 1); XCTAssertEqual(fetch.count, 0)
    }
    func testTwoSubscribersShareFetchAndCachedPlainServerTag() {
        let fetch = Fetch(), began = expectation(description: "one native request"), done = expectation(description: "two receipts")
        done.expectedFulfillmentCount = 2; fetch.started = { began.fulfill() }
        let lookup = ServerReleaseLookup(permitted: { true }, fetch: fetch.start); defer { lookup.shutdown() }
        for _ in 0..<2 { _ = lookup.latest { value in XCTAssertEqual(value, "server-v2.18"); done.fulfill() } }
        wait(for: [began], timeout: 1); fetch.complete(0, release); wait(for: [done], timeout: 1)
        let cached = expectation(description: "cached reply")
        _ = lookup.latest { value in XCTAssertEqual(value, "server-v2.18"); cached.fulfill() }
        wait(for: [cached], timeout: 1); XCTAssertEqual(fetch.count, 1)
    }
    func testCancellingOneSubscriberKeepsOtherRequestAlive() {
        let fetch = Fetch(), began = expectation(description: "native request"), done = expectation(description: "surviving subscriber")
        fetch.started = { began.fulfill() }
        let lookup = ServerReleaseLookup(permitted: { true }, fetch: fetch.start); defer { lookup.shutdown() }
        var firstReplies = 0
        let cancel = lookup.latest { _ in firstReplies += 1 }
        _ = lookup.latest { value in XCTAssertEqual(value, "server-v2.18"); done.fulfill() }
        wait(for: [began], timeout: 1); cancel(); fetch.complete(0, release); wait(for: [done], timeout: 1)
        XCTAssertEqual(firstReplies, 0); XCTAssertEqual(fetch.cancels, 0)
    }
    func testLastCancellationStopsExactFetchAndOldCompletionCannotReviveIt() {
        let fetch = Fetch(), began = expectation(description: "native request")
        fetch.started = { began.fulfill() }
        let lookup = ServerReleaseLookup(permitted: { true }, fetch: fetch.start)
        var replies = 0
        let cancel = lookup.latest { _ in replies += 1 }
        wait(for: [began], timeout: 1); cancel(); cancel(); lookup.shutdown(); lookup.shutdown()
        fetch.complete(0, release)
        XCTAssertEqual(fetch.cancels, 1); XCTAssertEqual(replies, 0)
    }
    func testFailureNotCachedAndDuplicateOldResultDoesNotReplaceRetry() {
        let fetch = Fetch(), began = expectation(description: "first request"), failed = expectation(description: "failure receipt")
        fetch.started = { began.fulfill() }
        let lookup = ServerReleaseLookup(permitted: { true }, fetch: fetch.start); defer { lookup.shutdown() }
        _ = lookup.latest { value in XCTAssertNil(value); failed.fulfill() }
        wait(for: [began], timeout: 1); fetch.complete(0, nil); wait(for: [failed], timeout: 1)
        let retry = expectation(description: "retry request"), done = expectation(description: "retry receipt")
        fetch.started = { retry.fulfill() }
        _ = lookup.latest { value in XCTAssertEqual(value, "server-v2.18"); done.fulfill() }
        wait(for: [retry], timeout: 1); fetch.complete(0, Data("[]".utf8)); fetch.complete(1, release)
        wait(for: [done], timeout: 1); XCTAssertEqual(fetch.count, 2)
    }
    func testOversizedAndMalformedRepliesFailWithoutPersistingAnything() {
        for data in [Data(repeating: 0, count: ServerReleaseLookup.maximumBytes + 1), Data("not json".utf8)] {
            let fetch = Fetch(), began = expectation(description: "bounded lookup"), done = expectation(description: "unavailable")
            fetch.started = { began.fulfill() }
            let lookup = ServerReleaseLookup(permitted: { true }, fetch: fetch.start)
            _ = lookup.latest { value in XCTAssertNil(value); done.fulfill() }
            wait(for: [began], timeout: 1); fetch.complete(0, data); wait(for: [done], timeout: 1); lookup.shutdown()
        }
    }
    func testShutdownBeforeLookupNeverConstructsTransport() {
        let fetch = Fetch(), done = expectation(description: "stopped provider")
        let lookup = ServerReleaseLookup(permitted: { true }, fetch: fetch.start); lookup.shutdown()
        _ = lookup.latest { value in XCTAssertNil(value); done.fulfill() }
        wait(for: [done], timeout: 1); XCTAssertEqual(fetch.count, 0)
    }
    func testSubscriberCanShutdownReentrantlyWithoutStartingAnotherRequest() {
        let fetch = Fetch(), began = expectation(description: "native request"), done = expectation(description: "reentrant shutdown")
        fetch.started = { began.fulfill() }
        let lookup = ServerReleaseLookup(permitted: { true }, fetch: fetch.start)
        _ = lookup.latest { value in XCTAssertEqual(value, "server-v2.18"); lookup.shutdown(); done.fulfill() }
        wait(for: [began], timeout: 1); fetch.complete(0, release); wait(for: [done], timeout: 1)
        XCTAssertEqual(fetch.count, 1)
    }

    func testOldDuplicateCannotHideActiveRetryCancellation() {
        let fetch = Fetch(), began = expectation(description: "first request"), failed = expectation(description: "failed first request")
        fetch.started = { began.fulfill() }
        let lookup = ServerReleaseLookup(permitted: { true }, fetch: fetch.start)
        _ = lookup.latest { value in XCTAssertNil(value); failed.fulfill() }
        wait(for: [began], timeout: 1); fetch.complete(0, nil); wait(for: [failed], timeout: 1)
        let retry = expectation(description: "pending retry"); fetch.started = { retry.fulfill() }
        _ = lookup.latest { _ in XCTFail("Cancelled retry must not reply") }
        wait(for: [retry], timeout: 1)
        fetch.complete(0, nil)
        lookup.shutdown()
        XCTAssertEqual(fetch.cancels, 1, "old receipt cannot erase the current native cancellation resource")
    }

}
