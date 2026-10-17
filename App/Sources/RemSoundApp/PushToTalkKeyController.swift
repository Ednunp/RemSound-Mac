import Foundation
import RemSoundCore
import RemSoundJam

/// Main-thread key ownership. Native registration is supplied by the App; this type installs no monitor or hook.
@MainActor
final class PushToTalkKeyController {
    var sendTalking: ((Bool, UUID) -> Void)?
    /// Real key transitions only. Configuration, capture-window and shutdown retirement are silent.
    var onTransition: ((Bool) -> Void)?
    private struct Context: Equatable {
        var settings: PushToTalkSettings
        var running: Bool
        var workerGeneration: UUID
        var permitted: Bool
    }
    private var context: Context?
    private var keys = PushToTalkKeyState()
    private var held = false
    private var captureWindowOpen = false
    private(set) var binding: HotkeyDescriptor?
    private(set) var eventGeneration = UUID()
    var talking: Bool { keys.talking }
    var isArmed: Bool {
        guard let context else { return false }
        return context.running && context.permitted && context.settings.enabled
            && context.settings.trigger == .key && binding != nil && !captureWindowOpen
    }

    func synchronize(settings: PushToTalkSettings, running: Bool, workerGeneration: UUID, permitted: Bool) {
        let next = Context(settings: settings, running: running, workerGeneration: workerGeneration, permitted: permitted)
        guard context != next else { return }
        retire()
        keys.configure(holdToSpeak: settings.holdToSpeak, doubleTapToHold: settings.doubleTapToHold,
                       speed: settings.doubleTapSpeed)
        context = next
    }
    /// The capture/registration owner validates the binding and persists it separately from profiles.
    func replaceBinding(_ value: HotkeyDescriptor?) {
        guard binding != value else { return }
        retire()
        binding = value
    }
    func setCaptureWindowOpen(_ open: Bool) {
        guard captureWindowOpen != open else { return }
        retire()
        captureWindowOpen = open
    }
    func shutdown() {
        retire()
        context = nil
        binding = nil
    }
    /// Native registration loss must invalidate held keys and queued callbacks without an off cue.
    func retireNativeEvents() { retire() }

    private func retire() {
        let wasTalking = keys.talking
        keys.reset()
        held = false
        eventGeneration = UUID()
        if wasTalking, let context { sendTalking?(false, context.workerGeneration) }
    }

    /// Match modifiers on the first press. Take repeats and release even if modifiers changed while held.
    /// Return false for unrelated, paused or obsolete callbacks so native input can continue normally.
    @discardableResult
    func handle(keyCode: UInt32, modifiers: HotkeyDescriptor.Modifiers, down: Bool, isRepeat: Bool = false,
                milliseconds: Int64, generation: UUID) -> Bool {
        guard isArmed, generation == eventGeneration, let binding, keyCode == binding.keyCode,
              let context else { return false }
        let changed: Bool
        if down {
            if held { return true }
            guard modifiers == binding.modifiers else { return false }
            // A repeat from a key held before retirement must not reopen the new profile/session.
            if isRepeat { return true }
            held = true
            changed = keys.press(atMilliseconds: milliseconds)
        } else {
            guard held else { return false }
            held = false
            changed = keys.release()
        }
        if changed {
            sendTalking?(keys.talking, context.workerGeneration)
            onTransition?(keys.talking)
        }
        return true
    }
}
