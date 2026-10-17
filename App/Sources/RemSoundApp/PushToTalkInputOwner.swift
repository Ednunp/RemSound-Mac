import Foundation
import RemSoundCore

/// Joins request acknowledgments, visible worker epochs and the exact native listener lifetime.
@MainActor
final class PushToTalkInputOwner {
    private let keys: PushToTalkKeyController
    private let registration: PushToTalkKeyRegistration
    private var desired: PushToTalkSettings
    private var pending: UUID?
    private var receipt: PushToTalkWorkerReceipt?
    private var receiptObserved = false
    private struct View {
        let settings: PushToTalkSettings
        let running: Bool
        let generation: UUID
    }
    private var view: View?
    private let idleGeneration = UUID()
    private var permitted: Bool
    private var reserved: [HotkeyDescriptor] = []
    private var closed = false
    var onFailure: ((String) -> Void)? {
        get { registration.onFailure }
        set { registration.onFailure = newValue }
    }
    var isRegistered: Bool { registration.isRegistered }
    var failure: String? { registration.failure }

    init(keys: PushToTalkKeyController, settings: PushToTalkSettings,
         backend: PushToTalkRegistrationBackend, permitted: Bool) {
        self.keys = keys; desired = settings; self.permitted = permitted
        registration = PushToTalkKeyRegistration(controller: keys, backend: backend)
    }
    @discardableResult
    func beginRequest(settings: PushToTalkSettings) -> UUID {
        let id = UUID()
        guard !closed else { return id }
        desired = settings; pending = id; receipt = nil; receiptObserved = false
        keys.retireNativeEvents()
        refresh()
        return id
    }
    func isCurrent(_ request: UUID) -> Bool { !closed && pending == request }
    func acknowledge(_ request: UUID, receipt result: PushToTalkWorkerReceipt?) {
        guard isCurrent(request) else { return }
        pending = nil
        guard let result, result.running, result.settings == desired else { refresh(); return }
        receipt = result
        receiptObserved = view?.running == true && view?.settings == result.settings && view?.generation == result.generation
        refresh()
    }
    func observe(settings: PushToTalkSettings, running: Bool, generation: UUID) {
        guard !closed else { return }
        view = .init(settings: settings, running: running, generation: generation)
        if !running { receipt = nil; receiptObserved = false }
        if let receipt, running, settings == receipt.settings, generation == receipt.generation {
            receiptObserved = true
        }
        refresh()
    }
    func setCapture(editorOpen: Bool, fieldFocused: Bool = false, windowKey: Bool = false) {
        guard !closed else { return }
        keys.setCaptureWindowOpen(editorOpen || (fieldFocused && windowKey))
        refresh()
    }
    func setReservedBindings(_ bindings: [HotkeyDescriptor]) {
        guard !closed else { return }
        reserved = bindings; refresh()
    }
    func setPermitted(_ allowed: Bool) {
        guard !closed else { return }
        permitted = allowed; refresh()
    }
    @discardableResult
    func replaceBinding(_ binding: HotkeyDescriptor?) -> Bool {
        guard !closed else { return false }
        return registration.replaceBinding(binding, generalBindings: reserved, permitted: permitted)
    }
    func retry() { guard !closed else { return }; registration.retry() }
    func invalidate() {
        guard !closed else { return }
        pending = nil; receipt = nil; receiptObserved = false
        keys.retireNativeEvents(); refresh()
    }
    func shutdown() {
        guard !closed else { return }
        invalidate(); registration.shutdown(); closed = true
    }
    private func refresh() {
        guard !closed else { return }
        let allowed = permitted && pending == nil && receipt != nil && receiptObserved
            && view?.running == true && view?.settings == desired
        keys.synchronize(settings: view?.settings ?? desired, running: view?.running ?? false,
            workerGeneration: view?.generation ?? idleGeneration, permitted: allowed)
        registration.refresh(generalBindings: reserved, permitted: allowed)
    }
}
