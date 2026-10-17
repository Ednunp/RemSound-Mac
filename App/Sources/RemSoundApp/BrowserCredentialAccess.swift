import Foundation
import RemSoundCore

protocol BrowserCredentialStorage: AnyObject {
    func load(maximumUTF8Bytes: Int) throws -> String?
    func save(_ password: String) throws
    func delete() throws
}
extension PasswordStore: BrowserCredentialStorage {}

private enum BrowserCredentialQueue {
    static let queue = DispatchQueue(label: "RemSound browser credential", qos: .utility)
}

@MainActor final class BrowserCredentialAccess {
    // The loaded value belongs only to the current UI request, never diagnostics.
    enum Outcome: Equatable, Sendable { case loaded(String?), stored, failed, stale }
    typealias Executor = (@escaping @Sendable () -> Void) -> Void
    private enum Action { case load, save(String), delete, deleteProfile }
    private weak var owner: BrowserSessionOwner?
    @MainActor private enum Context {
        case editor(BrowserSessionOwner.EditorTicket), configuration(BrowserSessionOwner.ConfigurationTicket), removal(BrowserSessionOwner.RemovalTicket)
        func current(_ owner: BrowserSessionOwner) -> Bool {
            switch self { case .editor(let ticket): return owner.isCurrentEditor(ticket); case .configuration(let ticket): return owner.isCurrentConfiguration(ticket); case .removal(let ticket): return owner.isCurrentRemoval(ticket) }
        }
        func reserve(_ owner: BrowserSessionOwner) -> BrowserSessionOwner.EditorWork? {
            switch self { case .editor(let ticket): return owner.reserveEditorWork(ticket); case .configuration(let ticket): return owner.reserveConfigurationWork(ticket); case .removal(let ticket): return owner.reserveRemovalWork(ticket) }
        }
        func end(_ owner: BrowserSessionOwner) {
            switch self { case .editor(let ticket): owner.endEditing(ticket); case .configuration(let ticket): owner.endConfiguration(ticket); case .removal(let ticket): owner.endRemoval(ticket) }
        }
        var isRemoval: Bool { if case .removal = self { return true }; return false }
        var allowsPersistence: Bool { if isRemoval { return false }; if case .configuration(let ticket) = self { return ticket.allowsPersistence }; return true }
        var allowsDeletion: Bool { isRemoval || allowsPersistence }
    }
    private let context: Context, storage: BrowserCredentialStorage
    private let removalAudio: BrowserCredentialStorage?
    private let isCurrent: () -> Bool, execute: Executor
    static func forProfile(owner: BrowserSessionOwner, editor: BrowserSessionOwner.EditorTicket, account: UUID,
                           isCurrent: @escaping () -> Bool) -> BrowserCredentialAccess? {
        guard AppRuntime.configuration != nil, owner.isCurrentEditor(editor), isCurrent() else { return nil }
        return .init(owner: owner, editor: editor, storage: AppRuntime.passwordStore(account: account.uuidString, role: .browser), isCurrent: isCurrent)
    }
    static func forConfiguration(owner: BrowserSessionOwner, configuration: BrowserSessionOwner.ConfigurationTicket,
                                 isCurrent: @escaping () -> Bool, execute: Executor? = nil) -> BrowserCredentialAccess? {
        guard AppRuntime.configuration != nil, owner.isCurrentConfiguration(configuration), isCurrent() else { return nil }
        let storage = AppRuntime.passwordStore(account: configuration.account.uuidString, role: .browser)
        if let execute { return .init(owner: owner, configuration: configuration, storage: storage, isCurrent: isCurrent, execute: execute) }
        return .init(owner: owner, configuration: configuration, storage: storage, isCurrent: isCurrent)
    }
    static func forRemoval(owner: BrowserSessionOwner, removal: BrowserSessionOwner.RemovalTicket,
                           isCurrent: @escaping () -> Bool, execute: Executor? = nil) -> BrowserCredentialAccess? {
        guard AppRuntime.configuration != nil, isCurrent(), owner.isCurrentRemoval(removal) else { return nil }
        let browser=AppRuntime.passwordStore(account:removal.account.uuidString,role:.browser)
        let audio=AppRuntime.passwordStore(account:removal.account.uuidString,role:.audio)
        return .init(owner:owner,removal:removal,browser:browser,audio:audio,isCurrent:isCurrent,
            execute:execute ?? { work in BrowserCredentialQueue.queue.async(execute:work) })
    }
    init(owner: BrowserSessionOwner, removal: BrowserSessionOwner.RemovalTicket, browser: BrowserCredentialStorage, audio: BrowserCredentialStorage,
         isCurrent: @escaping () -> Bool, execute: @escaping Executor) {
        self.owner=owner;context = .removal(removal);storage=browser;removalAudio=audio;self.isCurrent=isCurrent;self.execute=execute
    }
    init(owner: BrowserSessionOwner, configuration: BrowserSessionOwner.ConfigurationTicket, storage: BrowserCredentialStorage,
         isCurrent: @escaping () -> Bool, execute: @escaping Executor = { work in BrowserCredentialQueue.queue.async(execute: work) }) {
        self.owner = owner; context = .configuration(configuration); self.storage = storage; removalAudio=nil; self.isCurrent = isCurrent; self.execute = execute
    }
    init(owner: BrowserSessionOwner, editor: BrowserSessionOwner.EditorTicket, storage: BrowserCredentialStorage,
         isCurrent: @escaping () -> Bool, execute: @escaping Executor = { work in BrowserCredentialQueue.queue.async(execute: work) }) {
        self.owner = owner; context = .editor(editor); self.storage = storage; removalAudio=nil; self.isCurrent = isCurrent; self.execute = execute
    }
    func load(completion: @escaping (Outcome) -> Void) -> Bool { guard !context.isRemoval else { return false }; return start(.load, completion) }
    func save(_ password: String, completion: @escaping (Outcome) -> Void) -> Bool {
        guard context.allowsPersistence, !password.isEmpty, BrowserListenerEdit.fits(password) else { return false }
        return start(.save(password), completion)
    }
    func delete(completion: @escaping (Outcome) -> Void) -> Bool { guard context.allowsDeletion else { return false }; return start(context.isRemoval ? .deleteProfile:.delete, completion) }
    func invalidate() { if let owner { context.end(owner) } }
    private func start(_ action: Action, _ completion: @escaping (Outcome) -> Void) -> Bool {
        guard let owner, isCurrent(), context.current(owner), let token = context.reserve(owner) else { return false }
        let current = isCurrent, ticket = context
        let work = Work(storage, removalAudio, action, token, BrowserListenerEdit.maximumPasswordBytes) { [weak owner] result in
            DispatchQueue.main.async { [weak owner] in
                guard let owner else { return }
                let outcome = ticket.current(owner) && current() ? result : .stale
                _ = owner.completeEditorWork(token) { [weak owner] in
                    guard let owner else { return }
                    completion(ticket.current(owner) && current() ? outcome : .stale)
                }
            }
        }
        execute { work.run() }; return true
    }
    // One owner credit serializes storage. Only locked first-run/token flags cross
    // queues; the storage reference and action are exclusively used by this job.
    private final class Work: @unchecked Sendable {
        private let storage: BrowserCredentialStorage, audio: BrowserCredentialStorage?, action: Action, token: BrowserSessionOwner.EditorWork
        private let limit: Int
        private let reply: (Outcome) -> Void, lock = NSLock()
        private var started = false
        init(_ storage: BrowserCredentialStorage, _ audio: BrowserCredentialStorage?, _ action: Action, _ token: BrowserSessionOwner.EditorWork, _ limit: Int, _ reply: @escaping (Outcome) -> Void) {
            self.storage = storage; self.audio = audio; self.action = action; self.token = token; self.limit = limit; self.reply = reply
        }
        func run() {
            lock.lock(); guard !started else { lock.unlock(); return }; started = true; lock.unlock()
            guard token.mayBorrow else { reply(.stale); return }
            let result: Outcome
            do {
                switch action {
                case .load:
                    let value = try storage.load(maximumUTF8Bytes: limit)
                    if let value, value.utf8.prefix(limit + 1).count > limit { result = .failed } else { result = .loaded(value) }
                case .save(let value): try storage.save(value); result = .stored
                case .delete: try storage.delete(); result = .stored
                case .deleteProfile:
                    guard let audio else { reply(.failed); return }
                    try storage.delete()
                    // Each synchronous old-account delete may already have effects.
                    // Revocation between stores must not start a second operation.
                    guard token.mayBorrow else { reply(.stale); return }
                    try audio.delete(); result = .stored
                }
            } catch { result = .failed }
            // A synchronous store operation may already have affected its fixed old
            // account. Revocation suppresses success; it cannot promise rollback.
            reply(token.mayBorrow ? result : .stale)
        }
    }
    deinit { MainActor.assumeIsolated { if let owner { context.end(owner) } } }
}
