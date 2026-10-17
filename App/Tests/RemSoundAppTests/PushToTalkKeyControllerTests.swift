import Carbon
import RemSoundCore
import RemSoundJam
import XCTest
@testable import RemSoundApp

@MainActor
final class PushToTalkKeyControllerTests: XCTestCase {
    private let binding = HotkeyDescriptor(keyCode: UInt32(kVK_F9), modifiers: [.control, .shift])
    private final class Events {
        var sent: [(Bool, UUID)] = []
        var cues: [Bool] = []
    }
    private func enabled() -> PushToTalkSettings { var s = PushToTalkSettings(); s.enabled = true; return s }
    private func fixture(_ settings: PushToTalkSettings? = nil) -> (PushToTalkKeyController, Events, UUID) {
        let controller = PushToTalkKeyController(), events = Events(), worker = UUID()
        controller.sendTalking = { events.sent.append(($0, $1)) }
        controller.onTransition = { events.cues.append($0) }
        controller.synchronize(settings: settings ?? enabled(), running: true, workerGeneration: worker, permitted: true)
        controller.replaceBinding(binding)
        return (controller, events, worker)
    }
    @discardableResult
    private func key(_ controller: PushToTalkKeyController, down: Bool = true, ms: Int64 = 100,
                     generation: UUID? = nil, modifiers: HotkeyDescriptor.Modifiers? = nil,
                     code: UInt32? = nil) -> Bool {
        controller.handle(keyCode: code ?? binding.keyCode, modifiers: modifiers ?? binding.modifiers,
                          down: down, milliseconds: ms, generation: generation ?? controller.eventGeneration)
    }
    func testHoldRepeatAndChangedModifierReleaseProduceOnlyRealTransitions() {
        let (c, e, worker) = fixture()
        XCTAssertTrue(key(c)); XCTAssertTrue(key(c, ms: 120, modifiers: []))
        XCTAssertTrue(key(c, down: false, modifiers: []))
        XCTAssertFalse(key(c, down: false))
        XCTAssertEqual(e.sent.map(\.0), [true, false]); XCTAssertTrue(e.sent.allSatisfy { $0.1 == worker })
        XCTAssertEqual(e.cues, [true, false])
    }
    func testWrongKeyAndWrongInitialModifiersPassThrough() {
        let (c, e, _) = fixture()
        XCTAssertFalse(key(c, modifiers: [])); XCTAssertFalse(key(c, code: UInt32(kVK_F10)))
        XCTAssertFalse(key(c, down: false)); XCTAssertTrue(e.sent.isEmpty); XCTAssertTrue(e.cues.isEmpty)
    }
    func testUnchangedOwnerSnapshotPreservesGenerationAndHeldKey() {
        let (c, e, worker) = fixture(); let ticket = c.eventGeneration
        key(c); c.synchronize(settings: enabled(), running: true, workerGeneration: worker, permitted: true)
        XCTAssertEqual(c.eventGeneration, ticket); XCTAssertTrue(c.talking)
        c.replaceBinding(binding); XCTAssertEqual(c.eventGeneration, ticket)
        key(c, down: false, generation: ticket); XCTAssertEqual(e.cues, [true, false])
    }
    func testReconfigurationRejectsDelayedOldCallbackAndRetiresWithoutOffCue() {
        let (c, e, worker) = fixture(); let old = c.eventGeneration
        key(c); var s = enabled(); s.doubleTapSpeed = .slow
        c.synchronize(settings: s, running: true, workerGeneration: worker, permitted: true)
        XCTAssertFalse(c.talking); XCTAssertEqual(e.sent.map(\.0), [true, false]); XCTAssertEqual(e.cues, [true])
        XCTAssertFalse(key(c, generation: old)); XCTAssertEqual(e.sent.count, 2)
        XCTAssertTrue(key(c)); XCTAssertEqual(e.cues, [true, true])
    }
    func testOldReleaseCannotCloseNewGenerationHeldKey() {
        let (c, e, worker) = fixture(); let old = c.eventGeneration
        c.synchronize(settings: enabled(), running: true, workerGeneration: UUID(), permitted: true)
        key(c); XCTAssertFalse(key(c, down: false, generation: old)); XCTAssertTrue(c.talking)
        XCTAssertNotEqual(e.sent.last?.1, worker); XCTAssertEqual(e.cues, [true])
    }
    func testBindingReplacementRejectsAlreadyQueuedCallbacksAndReleasesOldWorker() {
        let (c, e, worker) = fixture(); let old = c.eventGeneration
        key(c); c.replaceBinding(HotkeyDescriptor(keyCode: UInt32(kVK_F10), modifiers: []))
        XCTAssertFalse(key(c, generation: old)); XCTAssertFalse(key(c))
        XCTAssertTrue(key(c, generation: c.eventGeneration, modifiers: [], code: UInt32(kVK_F10)))
        XCTAssertEqual(e.sent.map(\.0), [true, false, true]); XCTAssertTrue(e.sent.allSatisfy { $0.1 == worker })
        XCTAssertEqual(e.cues, [true, true])
    }
    func testCaptureWindowPassThroughRetiresLatchAndOldCallbackOnReopen() {
        var s = enabled(); s.holdToSpeak = false; s.doubleTapToHold = false
        let (c, e, _) = fixture(s); let old = c.eventGeneration
        key(c); key(c, down: false); XCTAssertTrue(c.talking)
        c.setCaptureWindowOpen(true)
        XCTAssertFalse(c.isArmed); XCTAssertFalse(key(c)); XCTAssertFalse(c.talking)
        c.setCaptureWindowOpen(false)
        XCTAssertTrue(c.isArmed); XCTAssertFalse(key(c, generation: old))
        XCTAssertEqual(e.cues, [true]); XCTAssertEqual(e.sent.map(\.0), [true, false])
        key(c); XCTAssertTrue(c.talking)
    }
    func testDisabledStoppedLevelAndUnpermittedContextsNeverTakeKeysOrPlayCues() {
        for mode in 0..<4 {
            let (c, e, worker) = fixture(); var s = enabled()
            if mode == 0 { s.enabled = false }; if mode == 2 { s.trigger = .level }
            c.synchronize(settings: s, running: mode != 1, workerGeneration: worker, permitted: mode != 3)
            XCTAssertFalse(c.isArmed); XCTAssertFalse(key(c)); XCTAssertTrue(e.sent.isEmpty); XCTAssertTrue(e.cues.isEmpty)
        }
    }
    func testLosingPermissionWhileHeldRetiresSilentlyAndOldCallbackStaysObsolete() {
        let (c, e, worker) = fixture(); let old = c.eventGeneration
        key(c); c.synchronize(settings: enabled(), running: true, workerGeneration: worker, permitted: false)
        c.synchronize(settings: enabled(), running: true, workerGeneration: worker, permitted: true)
        XCTAssertFalse(key(c, generation: old)); XCTAssertFalse(c.talking)
        XCTAssertEqual(e.sent.map(\.0), [true, false]); XCTAssertEqual(e.cues, [true])
    }
    func testDoubleTapUsesPortableLatchAndThirdTapRelease() {
        var s = enabled(); s.holdToSpeak = false
        let (c, e, _) = fixture(s)
        key(c, ms: 100); key(c, down: false, ms: 110); XCTAssertFalse(c.talking)
        key(c, ms: 600); key(c, down: false, ms: 610); XCTAssertTrue(c.talking)
        key(c, ms: 620); key(c, down: false, ms: 630); XCTAssertFalse(c.talking)
        XCTAssertEqual(e.cues, [true, false]); XCTAssertEqual(e.sent.map(\.0), [true, false])
    }
    func testShutdownInvalidatesCallbackClearsBindingAndReleasesWithoutCue() {
        let (c, e, _) = fixture(); let old = c.eventGeneration
        key(c); c.shutdown(); c.shutdown()
        XCTAssertNil(c.binding); XCTAssertFalse(c.isArmed); XCTAssertFalse(key(c, generation: old))
        XCTAssertEqual(e.sent.map(\.0), [true, false]); XCTAssertEqual(e.cues, [true])
    }
    func testRepeatAfterRetirementCannotBecomeANewPress() {
        let (c, e, worker) = fixture(); key(c)
        c.synchronize(settings: enabled(), running: true, workerGeneration: UUID(), permitted: true)
        XCTAssertTrue(c.handle(keyCode: binding.keyCode, modifiers: binding.modifiers, down: true,
                               isRepeat: true, milliseconds: 120, generation: c.eventGeneration))
        XCTAssertFalse(c.talking); XCTAssertEqual(e.cues, [true])
        XCTAssertEqual(e.sent.map(\.0), [true, false]); XCTAssertEqual(e.sent.last?.1, worker)
        XCTAssertFalse(key(c, down: false))
        XCTAssertTrue(key(c, ms: 200)); XCTAssertTrue(c.talking)
    }
    func testNoBindingNeverArmsAndClearingHeldBindingRetiresSilently() {
        let (c, e, _) = fixture(); key(c); c.replaceBinding(nil)
        XCTAssertFalse(key(c)); XCTAssertFalse(c.isArmed); XCTAssertFalse(c.talking)
        XCTAssertEqual(e.sent.map(\.0), [true, false]); XCTAssertEqual(e.cues, [true])
    }
}
