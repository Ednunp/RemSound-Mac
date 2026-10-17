import Foundation
import RemSoundCore

// Password-bearing values stay in this App editing lifetime, never Codable or diagnostic output.
struct BrowserListenerChoice: Equatable {
    var options: BrowserListenerOptions
    var password: String
    static let empty = Self(options: .init(), password: "")
}

@MainActor final class BrowserListenerEdit {
    static let maximumPasswordBytes = 1024
    enum End: Equatable { case accepted, cancelled, invalidated }
    typealias Apply = (BrowserListenerChoice, @escaping (Bool) -> Void) -> Bool
    private(set) var choice: BrowserListenerChoice
    private(set) var busy = false, finished = false
    private(set) var message = ""
    var changed: (() -> Void)?
    var ended: ((End, BrowserListenerChoice?) -> Void)?
    private var opened: BrowserListenerChoice, applied: BrowserListenerChoice, runtimeOpened: BrowserListenerChoice, persisted: BrowserListenerChoice
    private let commit: Apply?
    private var persistenceUncertain = false
    private(set) var saving = false
    private let isCurrent: () -> Bool, apply: Apply
    private var closing: End?, invalidated = false, uncertain = false
    private var presentation: UUID?
    // One native view may observe this model. This is UI ownership only; it
    // grants no storage, Session or native-listener authority.
    func claimPresentation() -> UUID? {
        guard presentation == nil, !finished, !invalidated, closing == nil else { return nil }
        let value = UUID(); presentation = value; return value
    }
    func releasePresentation(_ value: UUID) { if presentation == value { presentation = nil } }
    private var operation: UUID?
    var closingRequested: Bool { closing != nil }
    var contextInvalidated: Bool { invalidated }
    private final class Receipt {
        private let lock = NSLock(); private var taken = false
        var admitted = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; guard !taken else { return false }; taken = true; return true }
    }
    static func fits(_ password: String) -> Bool { password.utf8.prefix(maximumPasswordBytes + 1).count <= maximumPasswordBytes }
    init?(opened: BrowserListenerChoice, effectiveOpened: BrowserListenerChoice? = nil, isCurrent: @escaping () -> Bool, apply: @escaping Apply, commit: Apply? = nil) {
        guard Self.fits(opened.password), effectiveOpened.map({ Self.fits($0.password) }) != false else { return nil }
        choice = opened; self.opened = opened; persisted = opened
        runtimeOpened = effectiveOpened ?? opened; applied = runtimeOpened
        self.isCurrent = isCurrent; self.apply = apply; self.commit = commit
    }
    func update(_ value: BrowserListenerChoice) {
        guard !finished, closing == nil else { return }
        guard isCurrent(), !invalidated else { invalidate(); return }
        guard Self.fits(value.password) else { report("Password must be at most 1024 UTF-8 bytes."); return }
        choice = value; message = ""; pump()
    }
    func accept() {
        guard !finished, !invalidated, closing != .cancelled else { return }
        guard !choice.options.enabled || !choice.password.isEmpty else { report("A password is required to let a browser listen."); return }
        closing = .accepted; pump()
    }
    func cancel() {
        guard !finished else { return }
        closing = .cancelled; choice = opened; message = ""; pump()
    }
    func invalidate() {
        guard !finished else { return }
        invalidated = true; closing = .invalidated
        if !busy { finish(.invalidated, nil) }
        else { report("Profile or permission context changed. Waiting for already-submitted work to finish.") }
    }
    private var target: BrowserListenerChoice {
        if closing == .cancelled { return runtimeOpened }
        // Clearing an enabled password first retires its preview; a blank draft never
        // borrows the prior password or silently keeps the old credential live.
        if choice.options.enabled && choice.password.isEmpty {
            return .init(options: .init(autoStart: choice.options.autoStart), password: "")
        }
        return choice
    }
    private func pump() {
        guard !finished else { return }
        guard isCurrent(), !invalidated else { invalidate(); return }
        guard !busy else { changed?(); return }
        let next = target
        if next == applied && !uncertain {
            if let closing {
                if commit != nil && (closing == .accepted || (closing == .cancelled && (persistenceUncertain || persisted != opened))) {
                    persist(closing == .accepted ? choice : opened); return
                }
                finish(closing, choice); return
            }
            if choice.options.enabled && choice.password.isEmpty { message = "A password is required to let a browser listen." }
            changed?(); return
        }
        let id = UUID(), receipt = Receipt(); operation = id; busy = true; changed?()
        guard !finished, !invalidated, isCurrent() else {
            // No raw call was made; this local reservation has no cleanup receipt to invent.
            operation = nil; busy = false; invalidate(); return
        }
        if next != target {
            // A notification may synchronously request Cancel before any raw work starts.
            operation = nil; busy = false; pump(); return
        }
        receipt.admitted = apply(next) { [weak self] success in
            guard receipt.claim() else { return }
            DispatchQueue.main.async { [weak self] in
                guard receipt.admitted else { return }; self?.completed(id, next, success)
            }
        }
        if !receipt.admitted { DispatchQueue.main.async { [weak self] in self?.refused(id) } }
    }
    // Persistence is a separate receipt from runtime preview. A failed or cancelled
    // store call may have side effects, so Cancel must confirm opened persistence too.
    private func persist(_ value: BrowserListenerChoice) {
        guard let commit else { return }
        let id = UUID(), receipt = Receipt(), intent = closing
        operation = id; busy = true; saving = true; changed?()
        guard isCurrent(), !invalidated else { operation = nil; busy = false; saving = false; invalidate(); return }
        guard closing == intent else { operation = nil; busy = false; saving = false; pump(); return }
        receipt.admitted = commit(value) { [weak self] success in
            guard receipt.claim() else { return }
            DispatchQueue.main.async { [weak self] in
                guard receipt.admitted else { return }; self?.persistenceCompleted(id, value, success)
            }
        }
        if receipt.admitted { persistenceUncertain = true }
        else { DispatchQueue.main.async { [weak self] in self?.persistenceRefused(id, value) } }
    }
    private func persistenceCompleted(_ id: UUID, _ value: BrowserListenerChoice, _ success: Bool) {
        guard operation == id else { return }; operation = nil; busy = false; saving = false
        guard isCurrent(), !invalidated else { finish(.invalidated, nil); return }
        if success {
            persisted = value; persistenceUncertain = false; message = ""
            if closing == .accepted { finish(.accepted, choice) }
            else { pump() }
        } else {
            persistenceUncertain = true
            if closing == .accepted { closing = nil }
            report("Browser choices could not be saved. This window remains open; restoration may still be required.")
            if closing == .cancelled && value != opened { pump() }
        }
    }
    private func persistenceRefused(_ id: UUID, _ value: BrowserListenerChoice) {
        guard operation == id else { return }; operation = nil; busy = false; saving = false
        guard isCurrent(), !invalidated else { finish(.invalidated, nil); return }
        if closing == .accepted { closing = nil }
        report("Browser choice saving was refused. Try again or restore the opened choices.")
        if closing == .cancelled && value != opened { pump() }
    }
    private func completed(_ id: UUID, _ value: BrowserListenerChoice, _ success: Bool) {
        guard operation == id else { return }; operation = nil; busy = false
        guard isCurrent(), !invalidated else { finish(.invalidated, nil); return }
        if success { applied = value; uncertain = false; message = ""; pump() }
        else {
            uncertain = true; report("Browser choices could not be applied. Cleanup or restoration is not confirmed.")
            if target != value { pump() }
        }
    }
    private func refused(_ id: UUID) {
        guard operation == id else { return }; operation = nil; busy = false
        guard isCurrent(), !invalidated else { finish(.invalidated, nil); return }
        report("Browser choice submission was refused. Try again or restore the opened choices.")
    }
    private func report(_ text: String) { message = text; changed?() }
    private func finish(_ result: End, _ value: BrowserListenerChoice?) {
        guard !finished, !busy else { return }
        let current = isCurrent() && !invalidated
        finished = true; choice = .empty; opened = .empty; applied = .empty; runtimeOpened = .empty; persisted = .empty
        let callback = ended; ended = nil; changed = nil
        callback?(current ? result : .invalidated, current ? value : nil)
    }
}
