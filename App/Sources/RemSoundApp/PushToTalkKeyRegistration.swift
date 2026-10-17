import Foundation

struct PushToTalkNativeKeyEvent {
    let keyCode: UInt32
    let modifiers: HotkeyDescriptor.Modifiers
    let down: Bool
    let isRepeat: Bool
    let milliseconds: Int64
}

@MainActor
protocol PushToTalkRegistrationLifetime: AnyObject {
    func stop()
}

@MainActor
protocol PushToTalkRegistrationBackend: AnyObject {
    func install(receive: @escaping (PushToTalkNativeKeyEvent) -> Bool,
                 disabled: @escaping () -> Void) throws -> PushToTalkRegistrationLifetime
}

/// Owns one native registration; the backend owns its exact native resources.
@MainActor
final class PushToTalkKeyRegistration {
    private let controller: PushToTalkKeyController
    private let backend: PushToTalkRegistrationBackend
    private var token: PushToTalkRegistrationLifetime?
    private var ticket: UUID?
    private var installedGeneration: UUID?
    private var blockedChoice: Choice?
    private var reportingTransaction = false
    private var closed = false
    private var permitted = false
    private var generalBindings: [HotkeyDescriptor] = []
    private(set) var failure: String?
    var onFailure: ((String) -> Void)?
    var isRegistered: Bool { token != nil }

    private struct Choice: Equatable {
        let binding: HotkeyDescriptor
        let reserved: Set<HotkeyDescriptor>
    }
    init(controller: PushToTalkKeyController, backend: PushToTalkRegistrationBackend) {
        self.controller = controller
        self.backend = backend
    }
    deinit {
        // This App-owned main-actor object is released with the App's native owners.
        MainActor.assumeIsolated { token?.stop(); controller.retireNativeEvents() }
    }
    static func conflicts(_ binding: HotkeyDescriptor?, with generalBindings: [HotkeyDescriptor]) -> Bool {
        guard let binding else { return false }
        return generalBindings.contains { $0 == binding || $0.layoutFallbacks.contains(binding) }
    }
    func refresh(generalBindings: [HotkeyDescriptor] = [], permitted: Bool) {
        guard !closed else { return }
        self.generalBindings = generalBindings
        self.permitted = permitted
        guard permitted, controller.isArmed, let binding = controller.binding else {
            retire(retireKey: token != nil)
            return
        }
        let choice = Choice(binding: binding, reserved: Set(generalBindings.flatMap { [$0] + $0.layoutFallbacks }))
        // A failed/disabled registration needs an explicit retry or a changed choice, not another view tick.
        guard blockedChoice != choice else { retire(retireKey: token != nil); return }
        guard binding.isValidForPushToTalk, !choice.reserved.contains(binding) else {
            fail("The push-to-talk key is invalid or conflicts with another RemSound shortcut.", choice: choice)
            return
        }
        if token != nil, installedGeneration == controller.eventGeneration { return }
        retire(retireKey: token != nil)
        let generation = controller.eventGeneration, attempt = UUID()
        ticket = attempt
        do {
            let installed = try backend.install(receive: { [weak self] event in
                guard let self, !self.closed, self.permitted, self.token != nil,
                      self.ticket == attempt, self.controller.eventGeneration == generation else { return false }
                return self.controller.handle(keyCode: event.keyCode, modifiers: event.modifiers,
                    down: event.down, isRepeat: event.isRepeat, milliseconds: event.milliseconds, generation: generation)
            }, disabled: { [weak self] in
                guard let self, self.ticket == attempt else { return }
                self.fail("The push-to-talk key listener stopped. Retry it after checking Accessibility permission.", choice: choice)
            })
            // A backend can be disabled synchronously while installation is still in progress.
            guard ticket == attempt, controller.eventGeneration == generation, controller.isArmed, self.permitted else {
                installed.stop(); ticket = nil; return
            }
            token = installed
            installedGeneration = generation
            failure = nil
        } catch {
            guard ticket == attempt else { return }
            fail(error.localizedDescription, choice: choice)
        }
    }
    @discardableResult
    func replaceBinding(_ binding: HotkeyDescriptor?, generalBindings: [HotkeyDescriptor], permitted: Bool) -> Bool {
        guard !closed else { return false }
        guard binding == nil || (binding?.isValidForPushToTalk == true && !Self.conflicts(binding, with: generalBindings)) else {
            report("The push-to-talk key is invalid or conflicts with another RemSound shortcut.")
            return false
        }
        let previousFailure = failure
        reportingTransaction = true
        defer {
            reportingTransaction = false
            if let failure, failure != previousFailure { onFailure?(failure) }
        }
        blockedChoice = nil
        failure = nil
        let previous = controller.binding
        controller.replaceBinding(binding)
        refresh(generalBindings: generalBindings, permitted: permitted)
        guard binding != nil, permitted, controller.isArmed, !isRegistered else { return true }
        let rejected = failure ?? "The push-to-talk key could not be registered."
        controller.replaceBinding(previous)
        refresh(generalBindings: generalBindings, permitted: permitted)
        if previous != nil, controller.isArmed, !isRegistered {
            report(rejected + " The previous push-to-talk key could not be restored.")
        } else { report(rejected) }
        return false
    }
    func retry() {
        guard !closed else { return }
        blockedChoice = nil
        refresh(generalBindings: generalBindings, permitted: permitted)
    }
    func shutdown() {
        guard !closed else { return }
        closed = true
        retire(retireKey: true)
        blockedChoice = nil
    }
    private func retire(retireKey: Bool) {
        ticket = nil
        installedGeneration = nil
        let previous = token
        token = nil
        previous?.stop()
        if retireKey { controller.retireNativeEvents() }
    }
    private func fail(_ message: String, choice: Choice) {
        retire(retireKey: true)
        blockedChoice = choice
        report(message)
    }
    private func report(_ message: String) {
        guard failure != message else { return }
        failure = message
        if !reportingTransaction { onFailure?(message) }
    }
}
