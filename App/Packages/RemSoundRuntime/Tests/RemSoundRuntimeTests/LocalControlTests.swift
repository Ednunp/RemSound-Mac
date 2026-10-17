#if canImport(Darwin)
import Darwin
import XCTest
@testable import RemSoundRuntime

final class LocalControlTests: XCTestCase {
    private final class Count {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func increment() { lock.lock(); count += 1; lock.unlock() }
    }
    private func root() throws -> URL {
        let base = ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let folder = base.appendingPathComponent(String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
    private func server(at url: URL, timeout: TimeInterval = 0.2,
        handler: @escaping (ControlRequest) -> ControlReply = {
            ControlReply(request: $0, status: .ok, message: "Handled", state: ["running": "false"])
        }) throws -> LocalControlServer {
        let result = LocalControlServer(socketURL: url, timeout: timeout, handler: handler)
        try result.start()
        addTeardownBlock { XCTAssertTrue(result.stop()) }
        return result
    }
    private func connectRaw(_ url: URL) throws -> Int32 {
        let descriptor = try ControlTransport.makeSocket()
        var address = try ControlTransport.address(url.path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 && errno != EINPROGRESS { close(descriptor); throw LocalControlError.unavailable }
        try ControlTransport.wait(descriptor, events: Int16(POLLOUT), until: ControlTransport.deadline(1))
        return descriptor
    }
    private func rejected(_ data: Data, at url: URL, framed: Bool = true) throws {
        let descriptor = try connectRaw(url)
        defer { close(descriptor) }
        let limit = ControlTransport.deadline(1)
        if framed { try ControlTransport.sendFrame(data, maximum: 100_000, descriptor: descriptor, until: limit) }
        else { try ControlTransport.write(data, descriptor: descriptor, until: limit) }
        XCTAssertThrowsError(try ControlTransport.receiveFrame(maximum: ControlTransport.maximumReplyBytes,
            descriptor: descriptor, until: limit))
    }

    func testOwnerOnlyRoundTripPreservesRequestAndExposesNoTransportEcho() throws {
        let url = try root().appendingPathComponent("ctl")
        let secret = "throwaway-secret-not-for-reply"
        let requests = Count()
        _ = try server(at: url) { request in
            requests.increment()
            XCTAssertEqual(request.action, "set-password")
            XCTAssertEqual(request.arguments["value"], secret)
            return ControlReply(request: request, status: .ok, message: "Password supplied", state: ["password-present": "true"])
        }
        let request = ControlRequest(action: "set-password", arguments: ["value": secret])
        let reply = try LocalControlClient.send(request, to: url)
        XCTAssertEqual(reply.id, request.id)
        XCTAssertEqual(reply.status, .ok)
        XCTAssertEqual(reply.state, ["password-present": "true"])
        XCTAssertFalse(String(data: try JSONEncoder().encode(reply), encoding: .utf8)!.contains(secret))
        XCTAssertEqual(requests.value, 1)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testRefusesUnsafeParentSocketAndSymlinkWithoutChangingAnything() throws {
        let folder = try root(), url = folder.appendingPathComponent("ctl")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        XCTAssertThrowsError(try LocalControlServer(socketURL: url) {
            ControlReply(request: $0, status: .ok, message: "Unexpected")
        }.start())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let existing = try server(at: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: url.path)
        XCTAssertThrowsError(try LocalControlClient.send(ControlRequest(action: "status"), to: url))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        XCTAssertThrowsError(try LocalControlClient.send(ControlRequest(action: "status"), to: link))
        XCTAssertEqual(try LocalControlClient.send(ControlRequest(action: "status"), to: url).status, .ok)
        XCTAssertTrue(existing.stop())
    }

    func testDuplicateAndStaleNamesAreRefusedRatherThanUnlinked() throws {
        let url = try root().appendingPathComponent("ctl")
        let first = try server(at: url)
        let second = LocalControlServer(socketURL: url) { ControlReply(request: $0, status: .ok, message: "Wrong server") }
        XCTAssertThrowsError(try second.start())
        XCTAssertThrowsError(try first.start())
        XCTAssertEqual(try LocalControlClient.send(ControlRequest(action: "status"), to: url).message, "Handled")
        XCTAssertTrue(first.stop())
        let replacement = try server(at: url)
        XCTAssertTrue(first.stop())
        XCTAssertEqual(try LocalControlClient.send(ControlRequest(action: "status"), to: url).status, .ok)
        XCTAssertTrue(replacement.stop())
        try Data("existing marker".utf8).write(to: url)
        XCTAssertThrowsError(try second.start())
        XCTAssertEqual(try String(contentsOf: url), "existing marker")
    }

    func testMalformedOversizeAndWrongVersionRequestsNeverExecuteThenHealthyClientWorks() throws {
        let url = try root().appendingPathComponent("ctl")
        let requests = Count()
        _ = try server(at: url) {
            requests.increment()
            return ControlReply(request: $0, status: .ok, message: "Healthy")
        }
        try rejected(Data("not JSON".utf8), at: url)
        try rejected(Data([0xff, 0xff, 0xff, 0xff]), at: url, framed: false)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ControlRequest(action: "status"))) as! [String: Any]
        object["version"] = 2
        try rejected(JSONSerialization.data(withJSONObject: object), at: url)
        XCTAssertEqual(requests.value, 0)
        XCTAssertEqual(try LocalControlClient.send(ControlRequest(action: "status"), to: url).message, "Healthy")
        XCTAssertEqual(requests.value, 1)
    }

    func testRequestValidationAndTransportErrorsDoNotEchoValues() throws {
        let url = try root().appendingPathComponent("ctl")
        _ = try server(at: url)
        let secret = "test-secret"
        for request in [ControlRequest(action: "../shell", arguments: ["value": secret]),
            ControlRequest(action: "status", arguments: ["value": String(repeating: "a", count: 4097)]),
            ControlRequest(action: "status", arguments: ["value": "bad\0value"]),
            ControlRequest(action: "status", arguments: ["Bad Key": secret])] {
            XCTAssertThrowsError(try LocalControlClient.send(request, to: url)) { error in
                XCTAssertFalse(error.localizedDescription.contains(secret))
            }
        }
        var values = [String: String]()
        for index in 0..<17 { values["key\(index)"] = "test" }
        XCTAssertThrowsError(try LocalControlClient.send(ControlRequest(action: "status", arguments: values), to: url))
        XCTAssertThrowsError(try LocalControlClient.send(ControlRequest(action: "status"), to: url, timeout: .nan))
        XCTAssertThrowsError(try LocalControlClient.send(ControlRequest(action: "status"), to: url, timeout: .infinity))
        let oversized = Dictionary(uniqueKeysWithValues: (0..<16).map { ("key\($0)", String(repeating: "x", count: 4096)) })
        XCTAssertThrowsError(try LocalControlClient.send(ControlRequest(action: "status", arguments: oversized), to: url))
        XCTAssertEqual(try LocalControlClient.send(ControlRequest(action: "status"), to: url).status, .ok)
    }

    func testTruncatedClientTimesOutWithoutBlockingNextRequest() throws {
        let url = try root().appendingPathComponent("ctl")
        _ = try server(at: url, timeout: 0.15)
        let start = ProcessInfo.processInfo.systemUptime
        try rejected(Data([0, 0, 0, 100, 1]), at: url, framed: false)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertGreaterThanOrEqual(elapsed, 0.1)
        XCTAssertLessThan(elapsed, 1)
        XCTAssertEqual(try LocalControlClient.send(ControlRequest(action: "status"), to: url).status, .ok)
    }

    func testWrongReplyIdentityAndOversizedReplyAreRefused() throws {
        let firstURL = try root().appendingPathComponent("ctl")
        _ = try server(at: firstURL) { _ in ControlReply(request: ControlRequest(action: "status"), status: .ok, message: "Wrong id") }
        XCTAssertThrowsError(try LocalControlClient.send(ControlRequest(action: "status"), to: firstURL))
        let secondURL = try root().appendingPathComponent("ctl")
        _ = try server(at: secondURL) { ControlReply(request: $0, status: .ok, message: String(repeating: "x", count: 70_000)) }
        XCTAssertThrowsError(try LocalControlClient.send(ControlRequest(action: "status"), to: secondURL))
    }

    func testStopInterruptsPartialReadAndRemovesOnlyOriginalSocket() throws {
        let url = try root().appendingPathComponent("ctl")
        let instance = try server(at: url, timeout: 10)
        let descriptor = try connectRaw(url)
        defer { close(descriptor) }
        try ControlTransport.write(Data([0, 0]), descriptor: descriptor, until: ControlTransport.deadline(1))
        let began = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(instance.stop())
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertThrowsError(try LocalControlClient.send(ControlRequest(action: "status"), to: url))
        XCTAssertTrue(instance.stop())
        let secondURL = try root().appendingPathComponent("ctl")
        let second = try server(at: secondURL)
        try FileManager.default.removeItem(at: secondURL)
        try Data("replacement".utf8).write(to: secondURL)
        XCTAssertTrue(second.stop())
        XCTAssertEqual(try String(contentsOf: secondURL), "replacement")
    }

    func testStopDoesNotWaitForAlreadyRunningHandler() throws {
        let url = try root().appendingPathComponent("ctl")
        let entered = DispatchSemaphore(value: 0), completed = DispatchSemaphore(value: 0)
        let clientDone = DispatchSemaphore(value: 0)
        let instance = try server(at: url, timeout: 10) { request in
            entered.signal()
            Thread.sleep(forTimeInterval: 0.35)
            completed.signal()
            return ControlReply(request: request, status: .ok, message: "Finished")
        }
        DispatchQueue.global().async {
            _ = try? LocalControlClient.send(ControlRequest(action: "status"), to: url)
            clientDone.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        let began = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(instance.stop())
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 0.2)
        XCTAssertEqual(completed.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(clientDone.wait(timeout: .now() + 1), .success)
    }

    func testCancelledQueuedActionCannotRunLateAndPendingDispatchRemainsBounded() throws {
        let url = try root().appendingPathComponent("ctl")
        let ui = DispatchQueue(label: "isolated blocked UI test")
        let release = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0), drained = DispatchSemaphore(value: 0)
        let changed = Count(), dispatched = Count()
        ui.async { entered.signal(); _ = release.wait(timeout: .now() + 3) }
        defer { release.signal(); ui.sync {} }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        let instance = LocalControlServer(socketURL: url, timeout: 0.08, dispatcher: { operation in
            dispatched.increment()
            ui.async {
                if operation.begin(), operation.request.action == "set-input" { changed.increment() }
                operation.finish(ControlReply(request: operation.request, status: .ok, message: "Handled"))
                drained.signal()
            }
        })
        try instance.start()
        addTeardownBlock { XCTAssertTrue(instance.stop()) }
        let reply = try LocalControlClient.send(ControlRequest(action: "set-input"), to: url)
        XCTAssertEqual(reply.status, .error)
        for _ in 0..<10 {
            let busy = try LocalControlClient.send(ControlRequest(action: "status"), to: url)
            XCTAssertEqual(busy.status, .error)
            XCTAssertTrue(busy.message.contains("busy"))
        }
        XCTAssertEqual(dispatched.value, 1)
        release.signal()
        XCTAssertEqual(drained.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(changed.value, 0)
        XCTAssertEqual(try LocalControlClient.send(ControlRequest(action: "status"), to: url).status, .ok)
    }

    func testClientsEarlierDeadlinePreventsLaterQueuedChanges() throws {
        let url = try root().appendingPathComponent("ctl")
        let release = DispatchSemaphore(value: 0), drained = DispatchSemaphore(value: 0)
        let changed = Count()
        let instance = LocalControlServer(socketURL: url, timeout: 1, dispatcher: { operation in
            DispatchQueue.global().async {
                _ = release.wait(timeout: .now() + 1)
                if operation.begin() { changed.increment() }
                operation.finish(ControlReply(request: operation.request, status: .ok, message: "Handled"))
                drained.signal()
            }
        })
        try instance.start()
        addTeardownBlock { XCTAssertTrue(instance.stop()) }
        _ = try? LocalControlClient.send(ControlRequest(action: "set-input"), to: url, timeout: 0.05)
        release.signal()
        XCTAssertEqual(drained.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(changed.value, 0)
    }

    func testExpiredLeaseIsNeverClaimedOrFinishedTwice() {
        let acknowledged = Count()
        let request = ControlRequest(action: "set-input")
        let operation = ControlOperation(request: request, deadline: 0, acknowledge: { acknowledged.increment() })
        XCTAssertFalse(operation.begin())
        operation.finish(ControlReply(request: request, status: .ok, message: "Late"))
        operation.finish(ControlReply(request: request, status: .ok, message: "Again"))
        XCTAssertEqual(acknowledged.value, 1)
        XCTAssertEqual(operation.wait()?.status, .error)
    }

    func testPasswordResponsesCannotEchoValuesOrExposeSecretStateFields() throws {
        let url = try root().appendingPathComponent("ctl")
        let secret = "test-private-control-value"
        _ = try server(at: url) {
            ControlReply(request: $0, status: .ok, message: "Provided \(secret)",
                state: ["Password": secret, "token": "another private value", "note": "value=\(secret)", "password-present": "true"])
        }
        let reply = try LocalControlClient.send(ControlRequest(action: "set-password", arguments: ["value": secret]), to: url)
        let encoded = String(data: try JSONEncoder().encode(reply), encoding: .utf8)!
        XCTAssertFalse(encoded.contains(secret))
        XCTAssertFalse(encoded.contains("another private value"))
        XCTAssertNil(reply.state["Password"])
        XCTAssertNil(reply.state["token"])
        XCTAssertEqual(reply.state["password-present"], "true")
        XCTAssertEqual(reply.message, "Provided [redacted]")
    }

    func testAlreadyStartedActionReportsUnknownOutcomeAndBlocksFurtherDispatchUntilAcknowledged() throws {
        let url = try root().appendingPathComponent("ctl")
        let release = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        let calls = Count()
        let instance = LocalControlServer(socketURL: url, timeout: 0.08, dispatcher: { operation in
            calls.increment()
            guard operation.begin() else {
                operation.finish(ControlReply(request: operation.request, status: .error, message: "Cancelled"))
                return
            }
            DispatchQueue.global().async {
                _ = release.wait(timeout: .now() + 2)
                operation.finish(ControlReply(request: operation.request, status: .ok, message: "Late completion"))
                finished.signal()
            }
        })
        try instance.start()
        addTeardownBlock { XCTAssertTrue(instance.stop()) }
        defer { release.signal(); _ = finished.wait(timeout: .now() + 1) }
        let reply = try LocalControlClient.send(ControlRequest(action: "set-input"), to: url)
        XCTAssertEqual(reply.status, .waiting)
        XCTAssertTrue(reply.message.contains("outcome is not yet known"))
        let busy = try LocalControlClient.send(ControlRequest(action: "status"), to: url)
        XCTAssertEqual(busy.status, .error)
        XCTAssertTrue(busy.message.contains("busy"))
        XCTAssertEqual(calls.value, 1)
    }

    func testChurnKeepsDescriptorsBoundedAndSocketCanBeReusedAfterStop() throws {
        let folder = try root(), url = folder.appendingPathComponent("ctl")
        let initial = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        for _ in 0..<20 {
            let instance = try server(at: url)
            for _ in 0..<10 { XCTAssertEqual(try LocalControlClient.send(ControlRequest(action: "status"), to: url).status, .ok) }
            XCTAssertTrue(instance.stop())
        }
        let final = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        XCTAssertLessThanOrEqual(final, initial + 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testPeerPolicyFailsClosedAndLongOrAncestorLinkedPathsAreRejected() throws {
        XCTAssertTrue(ControlTransport.peerAllowed(actual: 501, owner: 501, real: 501, effective: 501))
        XCTAssertFalse(ControlTransport.peerAllowed(actual: nil, owner: 501, real: 501, effective: 501))
        XCTAssertFalse(ControlTransport.peerAllowed(actual: 502, owner: 501, real: 501, effective: 501))
        XCTAssertFalse(ControlTransport.peerAllowed(actual: 501, owner: 501, real: 502, effective: 501))
        XCTAssertFalse(ControlTransport.peerAllowed(actual: 501, owner: 502, real: 501, effective: 501))
        let folder = try root()
        XCTAssertThrowsError(try LocalControlServer(socketURL: folder.appendingPathComponent(String(repeating: "x", count: 200))) {
            ControlReply(request: $0, status: .ok, message: "Unexpected")
        }.start())
        let parent = try root(), link = parent.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        XCTAssertThrowsError(try LocalControlServer(socketURL: link.appendingPathComponent("ctl")) {
            ControlReply(request: $0, status: .ok, message: "Unexpected")
        }.start())
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("ctl").path))
    }

    func testFrameLimitsRefuseFiniteOversizeBeforeReadingOrWritingPayload() throws {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        guard descriptors.allSatisfy({ $0 >= 0 }) else { return }
        defer { descriptors.forEach { close($0) } }
        for descriptor in descriptors { XCTAssertEqual(fcntl(descriptor, F_SETFL, O_NONBLOCK), 0) }
        let payload = Data(repeating: 1, count: 65)
        XCTAssertThrowsError(try ControlTransport.sendFrame(payload, maximum: 64, descriptor: descriptors[0],
            until: ControlTransport.deadline(1))) { error in
            guard case LocalControlError.invalidMessage = error else { return XCTFail("Wrong frame-size refusal") }
        }
        try ControlTransport.sendFrame(payload, maximum: 1000, descriptor: descriptors[0], until: ControlTransport.deadline(1))
        XCTAssertThrowsError(try ControlTransport.receiveFrame(maximum: 64, descriptor: descriptors[1],
            until: ControlTransport.deadline(1))) { error in
            guard case LocalControlError.invalidMessage = error else { return XCTFail("Wrong frame-size refusal") }
        }
    }
}
#endif
