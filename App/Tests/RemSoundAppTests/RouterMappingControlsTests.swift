import AppKit
import RemSoundCore
import RemSoundRuntime
import XCTest
@testable import RemSoundApp

@MainActor
final class RouterMappingControlsTests: XCTestCase {
    private struct Refused: LocalizedError { var errorDescription: String? { "Cleanup refused." } }
    @MainActor private final class Lease: RouterMappingLease {
        var externalAddress: String? = "203.0.113.7", externalPort: UInt16 = 49321
        var validFor: TimeInterval = 3600
        var removals: [(Result<Void, Error>) -> Void] = []
        func renew(_ completion: @escaping (Result<TimeInterval, Error>) -> Void) -> () -> Void { completion(.success(3600)); return {} }
        func remove(_ completion: @escaping (Result<Void, Error>) -> Void) { removals.append(completion) }
    }
    @MainActor private final class Backend: RouterMappingBackend {
        var ports: [UInt16] = [], opened: [(Result<RouterMappingLease?, Error>) -> Void] = [], cancellations = 0
        var shutdowns: [(Result<Void, Error>) -> Void] = []
        func open(port: UInt16, leaseSeconds: Int, completion: @escaping (Result<RouterMappingLease?, Error>) -> Void) -> () -> Void {
            ports.append(port); opened.append(completion); return { self.cancellations += 1 }
        }
        func shutdown(_ completion: @escaping (Result<Void, Error>) -> Void) { shutdowns.append(completion) }
    }
    @MainActor private final class Fixture {
        let configuration: RuntimeConfiguration, backend = Backend()
        var c: RouterMappingControls!, factories = 0, ticks: [() -> Void] = [], wakes: [() -> Void] = []
        var tickStops = 0, wakeStops = 0, allowed = true, time: TimeInterval = 0
        var scheduleHook: (() -> Void)?, wakeHook: (() -> Void)?
        init() throws {
            _ = NSApplication.shared
            let base = ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"]!
            configuration = try .init(options: .parse(["--config-dir", base + "/router-controls-" + UUID().uuidString, "--headless", "--silent"]))
        }
        func build() {
            c = .init(configuration: configuration, allowed: { self.allowed }, clock: { self.time },
                makeBackend: { self.factories += 1; return self.backend },
                schedule: { self.ticks.append($0); self.scheduleHook?(); return { self.tickStops += 1 } },
                watchWake: { self.wakes.append($0); self.wakeHook?(); return { self.wakeStops += 1 } })
        }
        func enable() { c.checkbox.state = .on; c.choiceChanged() }
        @discardableResult func start(port: UInt16 = 49123) -> (UUID, SessionNetworkBinding) {
            let request = UUID(), binding = SessionNetworkBinding(port: port, generation: UUID())
            c.beginStart(request); c.observe(running: true, binding: binding); c.acknowledge(request, binding: binding); return (request, binding)
        }
        func finish() { c.shutdown(); backend.opened.forEach { $0(.success(nil)) }; backend.shutdowns.forEach { $0(.success(())) } }
    }
    private func fixture() throws -> Fixture { let f = try Fixture(); f.build(); addTeardownBlock { MainActor.assumeIsolated { f.finish() } }; return f }
    func testAbsentAndMalformedMachineChoiceRemainOffWithoutWritesOrFactories() throws {
        let f = try fixture(); XCTAssertFalse(f.c.enabled); XCTAssertNil(f.configuration.settings.object(forKey: RouterMappingControls.settingKey))
        f.configuration.settings.set("true", forKey: RouterMappingControls.settingKey); f.build(); f.start()
        XCTAssertFalse(f.c.enabled); XCTAssertEqual(f.factories, 0); XCTAssertTrue(f.ticks.isEmpty)
        XCTAssertEqual(f.configuration.settings.string(forKey: RouterMappingControls.settingKey), "true")
    }
    func testChoicePersistsOnlyMachineKeyWithoutProfileOrBindingData() throws {
        let f = try fixture(); f.configuration.settings.set("profile bytes", forKey: "activeProfileSettings"); f.enable()
        XCTAssertTrue(f.c.enabled); XCTAssertTrue(f.configuration.settings.bool(forKey: RouterMappingControls.settingKey))
        XCTAssertEqual(f.configuration.settings.string(forKey: "activeProfileSettings"), "profile bytes"); XCTAssertEqual(f.factories, 0)
        f.build(); XCTAssertTrue(f.c.enabled); XCTAssertTrue(f.ticks.isEmpty)
    }
    func testOldReceiptCannotOpenNewSocketOrConstructTimer() throws {
        let f = try fixture(); f.enable(); let old = UUID(), newest = UUID(), b = SessionNetworkBinding(port: 49123, generation: UUID())
        f.c.beginStart(old); f.c.beginStart(newest); f.c.observe(running: true, binding: b); f.c.acknowledge(old, binding: b)
        XCTAssertEqual(f.factories, 0); XCTAssertTrue(f.ticks.isEmpty); XCTAssertTrue(f.wakes.isEmpty)
        f.c.acknowledge(newest, binding: b); XCTAssertEqual(f.backend.ports, [49123]); XCTAssertEqual(f.ticks.count, 1)
    }
    func testReceiptAndObservedSocketMustMatchIncludingGeneration() throws {
        let f = try fixture(); f.enable(); let r = UUID(), b = SessionNetworkBinding(port: 49123, generation: UUID())
        f.c.beginStart(r); f.c.acknowledge(r, binding: b); XCTAssertEqual(f.factories, 0)
        f.c.observe(running: true, binding: .init(port: b.port, generation: UUID())); XCTAssertEqual(f.factories, 0)
        f.c.observe(running: true, binding: b); XCTAssertEqual(f.factories, 1)
    }
    func testPendingStartStopAndStaleCallbacksRetireExactDrivers() throws {
        let f = try fixture(); f.enable(); f.start(); f.backend.opened.first?(.success(nil))
        let tick = try XCTUnwrap(f.ticks.first), wake = try XCTUnwrap(f.wakes.first)
        f.c.beginStart(UUID()); XCTAssertEqual(f.tickStops, 1); XCTAssertEqual(f.wakeStops, 1)
        tick(); wake(); XCTAssertEqual(f.backend.ports.count, 1); f.c.invalidate(); XCTAssertEqual(f.tickStops, 1)
    }
    func testSamePortNewGenerationWaitsExactOldLeaseDeletion() throws {
        let f = try fixture(); f.enable(); f.start(); let lease = Lease(); f.backend.opened.first?(.success(lease))
        f.start(); XCTAssertEqual(lease.removals.count, 1); XCTAssertEqual(f.backend.ports.count, 1)
        lease.removals.first?(.success(())); XCTAssertEqual(f.backend.ports.count, 2); XCTAssertEqual(f.factories, 1)
    }
    func testFailedWritePreservesChoiceAndLiveMapping() throws {
        let f = try fixture(); f.enable(); f.start(); let lease = Lease(); f.backend.opened.first?(.success(lease))
        let file = f.configuration.root!.appendingPathComponent("settings.plist"), bytes = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file); try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: file); try? bytes.write(to: file) }
        f.c.checkbox.state = .off; f.c.choiceChanged()
        XCTAssertTrue(f.c.enabled); XCTAssertEqual(f.c.checkbox.state, .on); XCTAssertTrue(lease.removals.isEmpty)
        XCTAssertTrue(f.configuration.settings.bool(forKey: RouterMappingControls.settingKey)); XCTAssertTrue(f.c.status.string.contains("Could not save"))
        XCTAssertEqual(f.tickStops, 0)
    }
    func testIsolatedDefaultRefusesBeforeNativeConstructionEvenWithSavedOptIn() throws {
        let f = try Fixture(); f.configuration.settings.set(true, forKey: RouterMappingControls.settingKey)
        let c = RouterMappingControls(configuration: f.configuration)
        let r = UUID(), b = SessionNetworkBinding(port: 49123, generation: UUID()); c.beginStart(r); c.observe(running: true, binding: b); c.acknowledge(r, binding: b)
        XCTAssertTrue(c.enabled); XCTAssertTrue(c.status.string.contains("isolated")); c.shutdown()
    }
    func testRunningViewAloneAndZeroOrNilReceiptNeverOpen() throws {
        let f = try fixture(); f.enable(); let r = UUID(); f.c.beginStart(r); f.c.observe(running: true, binding: .init(port: 49123, generation: UUID()))
        f.c.acknowledge(r, binding: nil); XCTAssertEqual(f.factories, 0)
        let zero = SessionNetworkBinding(port: 0, generation: UUID()); f.c.observe(running: true, binding: zero); f.c.acknowledge(r, binding: zero)
        XCTAssertEqual(f.factories, 0)
    }
    func testFocusedNativeControlsHaveStableIdentityNamesAndTabOrder() throws {
        let f = try fixture(); let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }; window.contentView = f.c.view
        f.c.checkbox.nextKeyView = f.c.status; f.c.status.nextKeyView = f.c.checkbox
        XCTAssertEqual(f.c.keyViews.count, 2); XCTAssertTrue(f.c.keyViews[0] === f.c.checkbox)
        XCTAssertEqual(f.c.status.accessibilityLabel(), "Router port mapping status")
        window.makeFirstResponder(f.c.checkbox); window.selectNextKeyView(nil); XCTAssertTrue(window.firstResponder === f.c.status)
        window.selectPreviousKeyView(nil); XCTAssertTrue(window.firstResponder === f.c.checkbox)
        let old = f.c.status; f.enable(); f.start(); XCTAssertTrue(old === f.c.status); XCTAssertFalse(window.isVisible)
    }
    func testOffStopsWakeAndTimerBeforePendingLateMappingCleanup() throws {
        let f = try fixture(); f.enable(); f.start(); f.c.checkbox.state = .off; f.c.choiceChanged()
        XCTAssertEqual(f.tickStops, 1); XCTAssertEqual(f.wakeStops, 1); XCTAssertEqual(f.backend.cancellations, 1)
        let lease = Lease(); f.backend.opened.first?(.success(lease)); XCTAssertEqual(lease.removals.count, 1)
        lease.removals.first?(.success(())); XCTAssertEqual(f.backend.ports.count, 1)
    }
    func testShutdownWaitsBackendAndLeaseAndDoesNotConstructNewDrivers() throws {
        let f = try fixture(); f.enable(); f.start(); let lease = Lease(); f.backend.opened.first?(.success(lease)); var replies = 0
        f.c.shutdown { _ in replies += 1 }; XCTAssertEqual(f.tickStops, 1); XCTAssertEqual(f.wakeStops, 1); XCTAssertEqual(replies, 0)
        f.backend.shutdowns.first?(.success(())); XCTAssertEqual(replies, 0); lease.removals.first?(.success(())); XCTAssertEqual(replies, 1)
        f.c.shutdown { _ in replies += 1 }; XCTAssertEqual(replies, 2); f.start(); XCTAssertEqual(f.backend.ports.count, 1)
    }
    func testBlockedCleanupStopsDriversAndCannotResetOnWakeOrToggle() throws {
        let f = try fixture(); f.enable(); f.start(); let lease = Lease(); f.backend.opened.first?(.success(lease))
        let wake = try XCTUnwrap(f.wakes.first); f.start(); lease.removals.first?(.failure(Refused()))
        XCTAssertEqual(f.tickStops, 2); wake(); f.c.checkbox.state = .off; f.c.choiceChanged(); f.enable()
        XCTAssertEqual(f.backend.ports.count, 1); XCTAssertEqual(f.factories, 1)
    }
    func testPermissionRetirementStopsOwnedResourcesOnNextTick() throws {
        let f = try fixture(); f.enable(); f.start(); f.backend.opened.first?(.success(nil))
        f.allowed = false; f.ticks.first?(); XCTAssertEqual(f.tickStops, 1); XCTAssertEqual(f.wakeStops, 1)
        XCTAssertEqual(f.backend.ports.count, 1)
    }
    func testRetirementDuringTickFactoryClosesReturnedResourceBeforeWakeFactory() throws {
        let f = try fixture(); f.scheduleHook = { f.c.invalidate() }; f.enable(); f.start()
        XCTAssertEqual(f.tickStops, 1); XCTAssertTrue(f.wakes.isEmpty)
        XCTAssertEqual(f.backend.cancellations, 1)
    }
    func testRetirementDuringWakeFactoryClosesBothReturnedResources() throws {
        let f = try fixture(); f.wakeHook = { f.c.invalidate() }; f.enable(); f.start()
        XCTAssertEqual(f.tickStops, 1); XCTAssertEqual(f.wakeStops, 1); XCTAssertEqual(f.backend.cancellations, 1)
    }
    func testActualCleanupFailureReplacesPriorSaveError() throws {
        let f = try fixture(); f.enable(); f.start(); let lease = Lease(); f.backend.opened.first?(.success(lease))
        let file = f.configuration.root!.appendingPathComponent("settings.plist"), bytes = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file); try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: file); try? bytes.write(to: file) }
        f.c.checkbox.state = .off; f.c.choiceChanged(); XCTAssertTrue(f.c.status.string.contains("Could not save"))
        f.c.invalidate(); lease.removals.first?(.failure(Refused()))
        XCTAssertTrue(f.c.status.string.contains("Cleanup refused")); XCTAssertFalse(f.c.status.string.contains("remain in effect"))
    }
}
