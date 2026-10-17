import Foundation

@MainActor final class BrowserProfileRemoval {
    private static let maximumWaiters = 16
    enum Outcome: Equatable { case removed, cancelled, failed }
    typealias CloseEditor = (@escaping () -> Void) -> Bool
    private(set) var finished = false
    private let owner: BrowserSessionOwner, account: UUID
    private let closeEditor: CloseEditor, seal: () -> (() -> Bool)?
    private let makeAccess: (BrowserSessionOwner.RemovalTicket, @escaping () -> Bool) -> BrowserCredentialAccess?
    private let removeFile: () throws -> Void
    private var started = false, cancelled = false, modelClosed = false, closeRefused = false
    private var prepared = false, storing = false
    private var request: BrowserSessionOwner.RemovalRequest?, ticket: BrowserSessionOwner.RemovalTicket?
    private var access: BrowserCredentialAccess?, current: (() -> Bool)?, outcome: Outcome?
    private var completion: ((Outcome) -> Void)?, waiters = [(Outcome) -> Void]()
    init(owner: BrowserSessionOwner, account: UUID, closeEditor: @escaping CloseEditor,
         seal: @escaping () -> (() -> Bool)?, access: @escaping (BrowserSessionOwner.RemovalTicket, @escaping () -> Bool) -> BrowserCredentialAccess?,
         removeFile: @escaping () throws -> Void) {
        self.owner=owner;self.account=account;self.closeEditor=closeEditor;self.seal=seal
        makeAccess=access;self.removeFile=removeFile
    }
    func start(completion: @escaping (Outcome) -> Void) -> Bool {
        guard !started else {return false};started=true
        guard let request=owner.prepareRemoval(account:account,completion:{[weak self] ticket in
            guard let self,!prepared else {return};prepared=true;self.ticket=ticket
            DispatchQueue.main.async {[weak self] in self?.advance()}
        }) else {return false}
        self.request=request;self.completion=completion
        // Own preparation revokes the old editor revision synchronously. Seal the
        // Root identity only afterwards; no storage work may run during admission.
        current=seal();if current == nil {cancelled=true;owner.endRemoval(request)}
        let receipt=Receipt()
        let accepted=closeEditor {[weak self] in
            guard receipt.claim() else {return}
            DispatchQueue.main.async {[weak self] in
                guard receipt.admitted,let self,!modelClosed else {return}
                modelClosed=true;advance()
            }
        }
        receipt.admitted=accepted
        if !accepted {closeRefused=true;cancelled=true;owner.endRemoval(request)}
        return true
    }
    private var valid: Bool {!cancelled && current?()==true}
    private func advance() {
        guard !finished,!storing,prepared,modelClosed || closeRefused else {return}
        guard !closeRefused else {finish(.failed);return}
        guard valid else {finish(.cancelled);return}
        guard let ticket,owner.isCurrentRemoval(ticket) else {finish(.failed);return}
        guard let access=makeAccess(ticket,{[weak self] in self?.valid==true}),valid,owner.isCurrentRemoval(ticket) else {finish(.failed);return}
        self.access=access;storing=true
        let admitted=access.delete {[weak self] result in
            // The lower main delivery still owns its credential credit. The next
            // bounded main turn permits file work only after that delivery returns.
            DispatchQueue.main.async {[weak self] in self?.stored(result)}
        }
        if !admitted {storing=false;finish(.failed)}
    }
    private func stored(_ result:BrowserCredentialAccess.Outcome) {
        guard storing,!finished else {return};storing=false
        guard valid else {finish(.cancelled);return}
        guard result == .stored,let ticket,owner.isCurrentRemoval(ticket) else {finish(.failed);return}
        do {try removeFile();finish(valid ? .removed:.cancelled)} catch {finish(.failed)}
    }
    func cancel() {
        guard !finished else {return};cancelled=true
        if let request {owner.endRemoval(request)};access?.invalidate();advance()
    }
    func close(completion: @escaping (Outcome) -> Void) -> Bool {
        if let outcome {completion(outcome);return true}
        guard request != nil,waiters.count<Self.maximumWaiters else {return false}
        waiters.append(completion);cancel();return true
    }
    private func finish(_ result:Outcome) {
        guard !finished,!storing,prepared,modelClosed || closeRefused else {return}
        finished=true;outcome=result;current=nil
        access?.invalidate();access=nil;if let request {owner.endRemoval(request)}
        let callback=completion;completion=nil;let callbacks=waiters;waiters.removeAll()
        callback?(result);for value in callbacks {value(result)}
    }
    private final class Receipt: @unchecked Sendable {
        private let lock=NSLock();private var received=false
        var admitted=false // Main-thread only, inspected after the raw call returns.
        func claim()->Bool {lock.lock();defer {lock.unlock()};guard !received else {return false};received=true;return true}
    }
    deinit {MainActor.assumeIsolated {access?.invalidate();if let request {owner.endRemoval(request)}}}
}
