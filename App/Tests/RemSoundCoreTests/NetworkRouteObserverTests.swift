import XCTest
@testable import RemSoundCore

final class NetworkRouteObserverTests: XCTestCase {
    private let endpoint = Endpoint("127.0.0.1", 12345)
    private let route = NetworkRoute(sourceAddress: "127.0.0.1", interface: "lo0", interfaceType: "Loopback")

    private func waitUntilIdle(_ observer: NetworkRouteObserver, owner: DispatchQueue) {
        let end = ProcessInfo.processInfo.systemUptime + 2
        while owner.sync(execute: { observer.isPending }), ProcessInfo.processInfo.systemUptime < end {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertFalse(owner.sync { observer.isPending })
    }

    func testSlowLookupDoesNotBlockOwnerOrQueueRepeatedRequests() {
        let owner = DispatchQueue(label: "route-test-owner")
        let entered = expectation(description: "lookup entered")
        let returned = expectation(description: "owner kept running")
        let changed = expectation(description: "route delivered on owner")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let observer = NetworkRouteObserver(owner: owner, read: { [route] _ in
            entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 2), .success)
            return route
        })
        owner.async { [endpoint] in
            observer.request([endpoint], now: 0) { _, _ in
                dispatchPrecondition(condition: .onQueue(owner))
                changed.fulfill()
            }
        }
        wait(for: [entered], timeout: 1)
        owner.async { [endpoint] in
            for now in 1...500 { observer.request([endpoint], now: Double(now)) { _, _ in XCTFail("Duplicate lookup") } }
            returned.fulfill()
        }
        wait(for: [returned], timeout: 1)
        release.signal()
        wait(for: [changed], timeout: 1)
        waitUntilIdle(observer, owner: owner)
    }

    func testInvalidationDropsOldResultAndKeepsOneLookupAcrossRestart() {
        let owner = DispatchQueue(label: "route-test-generation")
        let entered = expectation(description: "old lookup entered")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        var calls = 0
        let observer = NetworkRouteObserver(owner: owner, read: { [route] _ in
            calls += 1
            if calls == 1 {
                entered.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 2), .success)
            }
            return route
        })
        owner.sync { observer.request([endpoint], now: 0) { _, _ in XCTFail("Stale result published") } }
        wait(for: [entered], timeout: 1)
        owner.sync {
            observer.invalidate()
            observer.request([endpoint], now: 10) { _, _ in XCTFail("Second lookup started while old one blocked") }
        }
        release.signal()
        waitUntilIdle(observer, owner: owner)
        let fresh = expectation(description: "fresh generation")
        owner.sync { observer.request([endpoint], now: 11) { _, value in
            XCTAssertEqual(value, self.route.description)
            fresh.fulfill()
        } }
        wait(for: [fresh], timeout: 1)
        waitUntilIdle(observer, owner: owner)
        XCTAssertEqual(calls, 2)
    }

    func testRefreshIsRateLimitedAndOnlyChangedRoutesArePublished() {
        let owner = DispatchQueue(label: "route-test-refresh")
        var calls = 0
        var changes: [String] = []
        let observer = NetworkRouteObserver(owner: owner, read: { [route] _ in
            calls += 1
            return calls < 3 ? route : nil
        })
        func request(_ now: Double) {
            owner.sync { observer.request([endpoint], now: now) { _, value in changes.append(value) } }
            waitUntilIdle(observer, owner: owner)
        }
        request(0)
        for now in [1.0, 2, 4.999] { request(now) }
        XCTAssertEqual(calls, 1)
        request(5)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(owner.sync { changes }, [route.description])
        request(10)
        request(15)
        XCTAssertEqual(owner.sync { changes }, [route.description, "unavailable"])
    }

    func testEmptyDestinationsDoNotStartAProbe() {
        let owner = DispatchQueue(label: "route-test-empty")
        let observer = NetworkRouteObserver(owner: owner, read: { _ in XCTFail("Empty destinations probed"); return nil })
        owner.sync {
            observer.request([], now: 0) { _, _ in XCTFail("Empty route reported") }
            observer.invalidate()
            observer.request([], now: 5) { _, _ in XCTFail("Empty route reported") }
            XCTAssertFalse(observer.isPending)
        }
    }
}
