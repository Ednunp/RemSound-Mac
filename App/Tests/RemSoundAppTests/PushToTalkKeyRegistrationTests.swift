import Carbon
import RemSoundCore
import RemSoundRuntime
import XCTest
@testable import RemSoundApp

@MainActor
final class PushToTalkKeyRegistrationTests: XCTestCase {
    private final class Token: PushToTalkRegistrationLifetime {
        var stops = 0
        var onStop: (() -> Void)?
        func stop() { stops += 1; onStop?() }
    }
    private final class Backend: PushToTalkRegistrationBackend {
        struct Attempt {
            let receive: (PushToTalkNativeKeyEvent) -> Bool
            let disabled: () -> Void
            let token: Token
        }
        struct Refused: LocalizedError { var errorDescription: String? { "Fixture registration refused." } }
        var attempts: [Attempt] = []
        var failNext = 0
        var disableDuringInstall = false
        var duringInstall: ((PushToTalkNativeKeyEvent) -> Bool) -> Void = { _ in }
        func install(receive: @escaping (PushToTalkNativeKeyEvent) -> Bool,
                     disabled: @escaping () -> Void) throws -> PushToTalkRegistrationLifetime {
            let token = Token(); attempts.append(.init(receive: receive, disabled: disabled, token: token))
            duringInstall(receive)
            if failNext > 0 { failNext -= 1; throw Refused() }
            if disableDuringInstall { disabled() }
            return token
        }
    }
    private final class Events { var sends: [Bool] = []; var cues: [Bool] = []; var failures: [String] = [] }
    private let binding = HotkeyDescriptor(keyCode: UInt32(kVK_ANSI_A), modifiers: [])
    private func enabled() -> PushToTalkSettings { var value = PushToTalkSettings(); value.enabled = true; return value }
    private func fixture() -> (PushToTalkKeyController, PushToTalkKeyRegistration, Backend, Events) {
        let c = PushToTalkKeyController(), b = Backend(), e = Events()
        c.synchronize(settings: enabled(), running: true, workerGeneration: UUID(), permitted: true)
        c.replaceBinding(binding); c.sendTalking = { value, _ in e.sends.append(value) }; c.onTransition = { e.cues.append($0) }
        let r = PushToTalkKeyRegistration(controller: c, backend: b); r.onFailure = { e.failures.append($0) }
        addTeardownBlock { r.shutdown(); c.shutdown() }; return (c, r, b, e)
    }
    private func event(down: Bool = true, repeatKey: Bool = false, code: Int = kVK_ANSI_A,
                       modifiers: HotkeyDescriptor.Modifiers = [], ms: Int64 = 100) -> PushToTalkNativeKeyEvent {
        .init(keyCode: UInt32(code), modifiers: modifiers, down: down, isRepeat: repeatKey, milliseconds: ms)
    }
    func testSingleOwnedRegistrationAndUnchangedRefreshPreserveHeldKey() throws {
        let (c, r, b, e) = fixture(); r.refresh(permitted: true)
        let a = try XCTUnwrap(b.attempts.first); XCTAssertTrue(a.receive(event()))
        let generation = c.eventGeneration; r.refresh(permitted: true)
        XCTAssertEqual(b.attempts.count, 1); XCTAssertEqual(c.eventGeneration, generation); XCTAssertTrue(c.talking)
        XCTAssertTrue(a.receive(event(down: false))); XCTAssertEqual(e.sends, [true, false]); XCTAssertEqual(a.token.stops, 0)
    }
    func testMatchingRepeatAndChangedModifierReleaseAreForwardedButUnrelatedKeysPass() throws {
        let (_, r, b, e) = fixture(); r.refresh(permitted: true); let a = try XCTUnwrap(b.attempts.first)
        XCTAssertFalse(a.receive(event(code: kVK_ANSI_Z))); XCTAssertFalse(a.receive(event(modifiers: [.control])))
        XCTAssertTrue(a.receive(event())); XCTAssertTrue(a.receive(event(repeatKey: true, modifiers: [.shift])))
        XCTAssertTrue(a.receive(event(down: false, modifiers: [.shift]))); XCTAssertEqual(e.cues, [true, false])
    }
    func testWorkerChangeRejectsOldEventsEvenBeforeNativeRefresh() throws {
        let (c, r, b, e) = fixture(); r.refresh(permitted: true); let old = try XCTUnwrap(b.attempts.first)
        XCTAssertTrue(old.receive(event())); c.synchronize(settings: enabled(), running: true, workerGeneration: UUID(), permitted: true)
        XCTAssertFalse(old.receive(event())); XCTAssertFalse(old.receive(event(down: false)))
        r.refresh(permitted: true); XCTAssertEqual(old.token.stops, 1); XCTAssertEqual(b.attempts.count, 2)
        XCTAssertTrue(b.attempts[1].receive(event(repeatKey: true))); XCTAssertFalse(c.talking)
        XCTAssertTrue(b.attempts[1].receive(event())); XCTAssertFalse(old.receive(event(down: false))); XCTAssertTrue(c.talking)
        XCTAssertEqual(e.cues, [true, true])
    }
    func testCapturePausePermissionLossAndStopRetireSilently() throws {
        let (c, r, b, e) = fixture(); r.refresh(permitted: true); let a = try XCTUnwrap(b.attempts.first)
        XCTAssertTrue(a.receive(event())); c.setCaptureWindowOpen(true); r.refresh(permitted: true)
        XCTAssertEqual(a.token.stops, 1); XCTAssertFalse(c.talking); XCTAssertFalse(a.receive(event()))
        c.setCaptureWindowOpen(false); r.refresh(permitted: true); XCTAssertEqual(b.attempts.count, 2)
        r.refresh(permitted: false); XCTAssertEqual(b.attempts[1].token.stops, 1)
        r.refresh(permitted: true); XCTAssertEqual(b.attempts.count, 3)
        c.synchronize(settings: enabled(), running: false, workerGeneration: UUID(), permitted: true); r.refresh(permitted: true)
        XCTAssertEqual(b.attempts[2].token.stops, 1); XCTAssertFalse(r.isRegistered); XCTAssertEqual(e.cues, [true])
    }
    func testLevelDisabledUnsetAndUnpermittedChoicesNeverCallBackend() {
        for mode in 0..<4 {
            let (c, r, b, _) = fixture(); var settings = enabled()
            if mode == 0 { settings.trigger = .level }
            if mode == 1 { settings.enabled = false }
            if mode == 2 { c.replaceBinding(nil) }
            c.synchronize(settings: settings, running: true, workerGeneration: UUID(), permitted: true)
            r.refresh(permitted: mode != 3); XCTAssertTrue(b.attempts.isEmpty); XCTAssertFalse(r.isRegistered)
        }
    }
    func testOwnShortcutAndLayoutAliasConflictsAreRefusedWithoutBackend() {
        let (c, r, b, e) = fixture(); r.refresh(generalBindings: [binding], permitted: true)
        XCTAssertTrue(b.attempts.isEmpty); XCTAssertNotNil(r.failure); XCTAssertEqual(e.failures.count, 1)
        for _ in 0..<3 { r.refresh(generalBindings: [binding], permitted: true) }; XCTAssertEqual(e.failures.count, 1)
        let uk = HotkeyDescriptor(keyCode: UInt32(kVK_ISO_Section), modifiers: [.control])
        let us = HotkeyDescriptor(keyCode: UInt32(kVK_ANSI_Backslash), modifiers: [.control])
        XCTAssertTrue(PushToTalkKeyRegistration.conflicts(uk, with: [us])); XCTAssertTrue(PushToTalkKeyRegistration.conflicts(us, with: [uk]))
        XCTAssertFalse(PushToTalkKeyRegistration.conflicts(binding, with: [us]))
        c.replaceBinding(uk); r.refresh(generalBindings: [us], permitted: true); XCTAssertTrue(b.attempts.isEmpty)
    }
    func testFailureRequiresExplicitRetryAndDoesNotRepeatOnNewWorkerViews() {
        let (c, r, b, e) = fixture(); b.failNext = 1; r.refresh(permitted: true)
        XCTAssertFalse(r.isRegistered); XCTAssertNotNil(r.failure)
        for _ in 0..<4 {
            c.synchronize(settings: enabled(), running: true, workerGeneration: UUID(), permitted: true); r.refresh(permitted: true)
        }
        XCTAssertEqual(b.attempts.count, 1); XCTAssertEqual(e.failures.count, 1)
        r.retry(); XCTAssertEqual(b.attempts.count, 2); XCTAssertTrue(r.isRegistered); XCTAssertNil(r.failure)
    }
    func testDisabledCallbackRetiresAndObsoleteDisabledCallbackCannotStopReplacement() throws {
        let (c, r, b, e) = fixture(); r.refresh(permitted: true); let old = try XCTUnwrap(b.attempts.first)
        XCTAssertTrue(old.receive(event())); old.disabled(); XCTAssertFalse(r.isRegistered); XCTAssertFalse(c.talking)
        XCTAssertEqual(old.token.stops, 1); XCTAssertEqual(e.cues, [true]); r.refresh(permitted: true); XCTAssertEqual(b.attempts.count, 1)
        r.retry(); XCTAssertEqual(b.attempts.count, 2); old.disabled(); XCTAssertEqual(b.attempts[1].token.stops, 0)
        XCTAssertTrue(b.attempts[1].receive(event())); XCTAssertFalse(old.receive(event(down: false)))
    }
    func testDisabledDuringInstallStopsReturnedResourceAndDoesNotRetry() {
        let (_, r, b, e) = fixture(); b.disableDuringInstall = true; r.refresh(permitted: true)
        XCTAssertEqual(b.attempts.count, 1); XCTAssertEqual(b.attempts.first?.token.stops, 1); XCTAssertFalse(r.isRegistered)
        r.refresh(permitted: true); XCTAssertEqual(b.attempts.count, 1); XCTAssertEqual(e.failures.count, 1)
    }
    func testCallbackDuringInstallCannotTakeKeys() {
        let (c, r, b, e) = fixture(); b.duringInstall = { receive in XCTAssertFalse(receive(self.event())) }
        r.refresh(permitted: true); XCTAssertFalse(c.talking); XCTAssertTrue(e.sends.isEmpty); XCTAssertTrue(r.isRegistered)
    }
    func testWorkerRetirementDuringInstallStopsStaleReturnedResource() {
        let (c, r, b, _) = fixture()
        b.duringInstall = { _ in c.synchronize(settings: self.enabled(), running: true, workerGeneration: UUID(), permitted: true) }
        r.refresh(permitted: true); XCTAssertEqual(b.attempts.count, 1); XCTAssertEqual(b.attempts.first?.token.stops, 1)
        XCTAssertFalse(r.isRegistered); XCTAssertNil(r.failure)
        b.duringInstall = { _ in }; r.refresh(permitted: true); XCTAssertEqual(b.attempts.count, 2); XCTAssertTrue(r.isRegistered)
    }
    func testReentrantStopAndShutdownCleanOneResourceAndNeverRestart() throws {
        let (c, r, b, e) = fixture(); r.refresh(permitted: true); let a = try XCTUnwrap(b.attempts.first)
        a.token.onStop = a.disabled; XCTAssertTrue(a.receive(event())); r.shutdown(); r.shutdown(); r.retry(); r.refresh(permitted: true)
        XCTAssertEqual(a.token.stops, 1); XCTAssertFalse(c.talking); XCTAssertEqual(b.attempts.count, 1); XCTAssertTrue(e.failures.isEmpty)
        XCTAssertFalse(a.receive(event())); XCTAssertEqual(e.cues, [true])
    }
    func testInvalidProposedBindingPreservesWorkingRegistration() throws {
        let (c, r, b, _) = fixture(); r.refresh(permitted: true); let a = try XCTUnwrap(b.attempts.first); let generation = c.eventGeneration
        XCTAssertFalse(r.replaceBinding(.init(keyCode: UInt32(kVK_Escape), modifiers: []), generalBindings: [], permitted: true))
        XCTAssertEqual(c.binding, binding); XCTAssertEqual(c.eventGeneration, generation); XCTAssertEqual(a.token.stops, 0); XCTAssertTrue(r.isRegistered)
        XCTAssertFalse(r.replaceBinding(binding, generalBindings: [binding], permitted: true)); XCTAssertEqual(a.token.stops, 0)
    }
    func testFailedReplacementRestoresOldBindingAndReportsOnce() throws {
        let (c, r, b, e) = fixture(); r.refresh(permitted: true); let old = try XCTUnwrap(b.attempts.first)
        b.failNext = 1
        let next = HotkeyDescriptor(keyCode: UInt32(kVK_ANSI_Z), modifiers: [])
        XCTAssertFalse(r.replaceBinding(next, generalBindings: [], permitted: true))
        XCTAssertEqual(c.binding, binding); XCTAssertEqual(old.token.stops, 1); XCTAssertEqual(b.attempts.count, 3); XCTAssertTrue(r.isRegistered)
        XCTAssertFalse(old.receive(event())); XCTAssertTrue(b.attempts[2].receive(event())); XCTAssertEqual(e.failures.count, 1)
    }
    func testFailedRestoreRemainsUnregisteredWithTruthfulFailure() {
        let (c, r, b, _) = fixture(); r.refresh(permitted: true); b.failNext = 2
        XCTAssertFalse(r.replaceBinding(.init(keyCode: UInt32(kVK_ANSI_Z), modifiers: []), generalBindings: [], permitted: true))
        XCTAssertEqual(c.binding, binding); XCTAssertFalse(r.isRegistered); XCTAssertTrue(r.failure?.contains("could not be restored") == true)
        r.refresh(permitted: true); XCTAssertEqual(b.attempts.count, 3)
    }
    func testExplicitClearRemovesRegistrationWithoutInventingDefault() throws {
        let (c, r, b, _) = fixture(); r.refresh(permitted: true); let old = try XCTUnwrap(b.attempts.first)
        XCTAssertTrue(r.replaceBinding(nil, generalBindings: [], permitted: true)); XCTAssertNil(c.binding); XCTAssertEqual(old.token.stops, 1)
        XCTAssertFalse(r.isRegistered); XCTAssertFalse(old.receive(event()))
    }
    func testOwnerReleaseStopsItsResourceAndSilentlyRetiresHeldKey() throws {
        let c = PushToTalkKeyController(), b = Backend(), e = Events()
        c.synchronize(settings: enabled(), running: true, workerGeneration: UUID(), permitted: true)
        c.replaceBinding(binding); c.onTransition = { e.cues.append($0) }
        defer { c.shutdown() }
        var owner: PushToTalkKeyRegistration? = .init(controller: c, backend: b)
        owner?.refresh(permitted: true); let a = try XCTUnwrap(b.attempts.first); XCTAssertTrue(a.receive(event()))
        owner = nil
        XCTAssertEqual(a.token.stops, 1); XCTAssertFalse(c.talking); XCTAssertFalse(a.receive(event(down: false)))
        XCTAssertEqual(e.cues, [true])
    }
    func testBackendRefusesIsolatedCopiesBeforeEvenPermissionPreflight() throws {
        guard let base = ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"] else { return XCTFail("Requires isolated test root") }
        for flags in [[], ["--silent"], ["--headless"]] {
            let root = URL(fileURLWithPath: base).appendingPathComponent("native-key-" + UUID().uuidString)
            let config = try RuntimeConfiguration(options: LaunchOptions.parse(flags + ["--config-dir", root.path]))
            defer { try? FileManager.default.removeItem(at: root) }
            var permissions = 0
            let backend = CoreGraphicsPushToTalkBackend(configuration: config, preflight: { permissions += 1; return true })
            XCTAssertThrowsError(try backend.install(receive: { _ in XCTFail("No actual key callback"); return false }, disabled: { XCTFail("No actual tap") }))
            XCTAssertEqual(permissions, 0)
        }
    }
}
