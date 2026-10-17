import Foundation
import RemSoundCore

// One Root window transaction. Core/App owners keep raw storage and native credits;
// this lifetime also joins the model's queued main-thread completion before closing.
@MainActor final class BrowserProfileTransaction {
    private static let maximumCloseWaiters = 16
    let ticket: BrowserSessionOwner.ConfigurationTicket
    private let owner: BrowserSessionOwner, access: BrowserCredentialAccess
    private let options: BrowserListenerOptions, isCurrentRoot: () -> Bool
    private let commitMetadata: (BrowserListenerOptions) -> Bool
    private var effectiveOpened: BrowserListenerChoice, temporaryPassword: String?
    private var started = false, loading = false, invalidated = false
    private var waiters = [() -> Void]()
    private var pendingEnd: (BrowserListenerEdit.End, BrowserListenerChoice?)?
    private(set) var address: BrowserListenerAddressModel?
    private(set) var model: BrowserListenerEdit?, finished = false, message = ""
    var onEnd: ((BrowserListenerEdit.End, BrowserListenerChoice?) -> Void)?
    var onEffective: ((BrowserListenerChoice) -> Void)?
    init(owner: BrowserSessionOwner, ticket: BrowserSessionOwner.ConfigurationTicket, access: BrowserCredentialAccess,
         options: BrowserListenerOptions, effectiveOpened: BrowserListenerChoice = .empty, temporaryPassword: String? = nil,
         isCurrent: @escaping () -> Bool, commitMetadata: @escaping (BrowserListenerOptions) -> Bool) {
        self.owner = owner; self.ticket = ticket; self.access = access; self.options = options
        self.effectiveOpened = effectiveOpened; self.temporaryPassword = temporaryPassword
        isCurrentRoot = isCurrent; self.commitMetadata = commitMetadata
    }
    private var current: Bool { !invalidated && !finished && isCurrentRoot() && owner.isCurrentConfiguration(ticket) }
    func open(completion: @escaping (BrowserListenerEdit?) -> Void) -> Bool {
        guard !started, current, BrowserListenerEdit.fits(effectiveOpened.password),
              temporaryPassword.map({ BrowserListenerEdit.fits($0) }) != false else { return false }
        started = true; loading = true
        let admitted = access.load { [weak self] outcome in
            // Credential delivery still owns the lower non-reentrant credit. The
            // editor may be used immediately after this next, bounded main turn.
            DispatchQueue.main.async { [weak self] in self?.loaded(outcome, completion) }
        }
        if !admitted { loading = false; message = "Browser password loading was refused."; finish(.invalidated, nil) }
        return admitted
    }
    private func loaded(_ outcome: BrowserCredentialAccess.Outcome, _ completion: @escaping (BrowserListenerEdit?) -> Void) {
        guard loading else { return }; loading = false
        guard current, case .loaded(let password) = outcome, password != "" else {
            message = "Browser password could not be loaded in the current profile. No choices were saved."
            completion(nil); finish(.invalidated, nil); return
        }
        let shown = ticket.allowsPersistence ? (password ?? "") : (temporaryPassword ?? password ?? "")
        let opened = BrowserListenerChoice(options: options, password: shown)
        guard let edit = BrowserListenerEdit(opened: opened, effectiveOpened: effectiveOpened, isCurrent: { [weak self] in self?.current == true }, apply: { [weak self] choice,reply in
            self?.apply(choice, completion: reply) ?? false
        }, commit: { [weak self] choice,reply in self?.commit(choice, completion: reply) ?? false }) else {
            message = "Browser choices are unavailable."; completion(nil); finish(.invalidated, nil); return
        }
        model = edit
        let address=BrowserListenerAddressModel(owner:owner,ticket:ticket,isCurrent:{ [weak self, weak edit] in
            self?.current == true && edit?.busy == false && edit?.closingRequested == false && edit?.finished == false
        })
        self.address=address
        address.changed={ [weak self] in
            guard let self, self.address?.busy == false, let pending=self.pendingEnd else {return}
            self.pendingEnd=nil
            DispatchQueue.main.async { [weak self] in self?.finish(pending.0,pending.1) }
        }
        let changed=edit.changed
        edit.changed={ [weak address, weak edit] in changed?();if edit?.busy == true {address?.clear()} }
        edit.ended = { [weak self] in self?.finish($0, $1) }
        completion(edit)
    }
    private func apply(_ choice: BrowserListenerChoice, completion: @escaping (Bool) -> Void) -> Bool {
        guard current else { return false }
        return owner.apply(choice, configuration: ticket) { [weak self] result in
            guard let self else { return }
            let success = self.current && result != .failed
            if success { self.onEffective?(result == .listening ? choice : .empty) }
            completion(success && self.current)
        }
    }
    private func commit(_ choice: BrowserListenerChoice, completion: @escaping (Bool) -> Void) -> Bool {
        guard current else { return false }
        let complete: (Bool) -> Void = { [weak self] stored in
            guard let self else { return }
            let kept = stored && self.current && self.commitMetadata(choice.options)
            completion(kept && self.current)
        }
        if !ticket.allowsPersistence {
            guard let work = owner.reserveConfigurationWork(ticket) else { return false }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                _ = self.owner.completeEditorWork(work) { complete(true) }
            }
            return true
        }
        let reply: (BrowserCredentialAccess.Outcome) -> Void = { complete($0 == .stored) }
        return choice.password.isEmpty ? access.delete(completion: reply) : access.save(choice.password, completion: reply)
    }
    func invalidate() {
        guard !finished else { return }; invalidated = true; temporaryPassword = nil
        address?.invalidate(); model?.invalidate(); access.invalidate()
        if !loading, model == nil { finish(.invalidated, nil) }
    }
    func close(completion: @escaping () -> Void) -> Bool {
        if finished { completion(); return true }
        guard waiters.count < Self.maximumCloseWaiters else { return false }
        waiters.append(completion); invalidate(); return true
    }
    private func finish(_ result: BrowserListenerEdit.End, _ value: BrowserListenerChoice?) {
        guard !finished, !loading, model?.busy != true else { return }
        if address?.busy == true {pendingEnd=(result,value);address?.invalidate();return}
        let valid = current
        address?.invalidate()
        finished = true; temporaryPassword = nil; effectiveOpened = .empty
        owner.endConfiguration(ticket)
        let ended = onEnd; onEnd = nil; onEffective = nil
        ended?(valid ? result : .invalidated, valid ? value : nil)
        let callbacks = waiters; waiters.removeAll(); for callback in callbacks { callback() }
    }
    deinit { MainActor.assumeIsolated { address?.invalidate(); model?.invalidate(); access.invalidate() } }
}
