import Foundation
import RemSoundCore

@MainActor protocol BrowserSessionBackend: AnyObject {
    var listenerState: BrowserListenerStatus.State { get }
    var supportsStoppedListening: Bool { get }
    var supportsAudioContinuity: Bool { get }
    func activateStopped(_ request: UUID, options: BrowserListenerOptions, password: String, completion: @escaping (BrowserListenerActivationResult) -> Void) -> Bool
    func prepareAudioTransition(_ request: UUID, completion: @escaping (Bool) -> Void) -> Bool
    func attachAudio(_ request: UUID, binding: SessionNetworkBinding, completion: @escaping (Bool) -> Void) -> Bool
    func prepareStart(_ request: UUID, completion: @escaping (Bool) -> Void) -> Bool
    func activate(_ request: UUID, binding: SessionNetworkBinding, options: BrowserListenerOptions, password: String) -> Bool
    func activate(_ request: UUID, binding: SessionNetworkBinding, options: BrowserListenerOptions, password: String, completion: @escaping (BrowserListenerActivationResult) -> Void) -> Bool
    func refreshAddress(completion: @escaping (BrowserListenerAddressResult) -> Void) -> Bool
    func reviewPublicAccess(completion: @escaping (BrowserListenerFunnelReviewResult) -> Void) -> Bool
    func turnOnPublicAccess(completion: @escaping (BrowserListenerFunnelResult) -> Void) -> Bool
    func cancelAddressRefresh()
    func copyAddress(_ value: BrowserListenerAddress, completion: @escaping (String?) -> Void) -> Bool
    func stop(completion: @escaping () -> Void) -> Bool
    func shutdown(completion: @escaping () -> Void) -> Bool
}
extension BrowserSessionBackend {
    var supportsAudioContinuity: Bool { false }
    func prepareAudioTransition(_ request: UUID, completion: @escaping (Bool) -> Void) -> Bool { prepareStart(request,completion:completion) }
    func attachAudio(_ request: UUID, binding: SessionNetworkBinding, completion: @escaping (Bool) -> Void) -> Bool { false }
    var supportsStoppedListening: Bool { false }
    func activateStopped(_ request: UUID, options: BrowserListenerOptions, password: String, completion: @escaping (BrowserListenerActivationResult) -> Void) -> Bool { false }

    // Older backends explicitly refuse; no synthetic successful address fallback.
    func refreshAddress(completion: @escaping (BrowserListenerAddressResult) -> Void) -> Bool { false }
    func reviewPublicAccess(completion: @escaping (BrowserListenerFunnelReviewResult) -> Void) -> Bool { false }
    func turnOnPublicAccess(completion: @escaping (BrowserListenerFunnelResult) -> Void) -> Bool { false }
    func cancelAddressRefresh() {}
    func copyAddress(_ value: BrowserListenerAddress, completion: @escaping (String?) -> Void) -> Bool { false }
}
extension BrowserListenerService: BrowserSessionBackend {
    var supportsStoppedListening: Bool { true }
    var supportsAudioContinuity: Bool { true }
    var listenerState: BrowserListenerStatus.State { status.state }
}

// Main-queue request ownership; Core retains every native/source retirement authority.
@MainActor final class BrowserSessionOwner {
    private static let maximumWaiters = 16
    enum Mutation: CaseIterable { case stopSession, applications, audioOptions }
    enum Failure: LocalizedError { case retirementRefused; var errorDescription: String? { "Browser listener retirement was not admitted." } }
    var onFailure: (() -> Void)?
    var onListenerFailure: (() -> Void)?
    var onConfigurationInvalidated: (() -> Void)?
    var onAudioConfigurationInvalidated: (() -> Void)?
    func refreshFailure() {
        guard active else { return }
        let prior = scope
        guard backend.listenerState == .unavailable, active, prior == scope, !closed, !blocked else { return }
        active = false; suspendSource(); onListenerFailure?()
    }
    var hasPendingSourceWork: Bool { !jobs.isEmpty }
    var sourceScope: UUID { scope }
    func isCurrentSourceScope(_ value: UUID) -> Bool { !closed && !blocked && value == scope }
    struct VisitTicket: Equatable {
        fileprivate let context: UUID, scope: UUID, request: UUID
        fileprivate let binding: SessionNetworkBinding
        fileprivate let worker: UUID
    }
    var currentVisitTicket: VisitTicket? {
        guard !closed, !blocked, !reservingRemoval, removalPreparation == nil, removalTicket == nil, rootPrepared, permission, !dirty, !delivering,
              operation == nil, preview == nil, editorWork == nil, jobs.isEmpty, mutations.isEmpty, desired == nil,
              let request, let binding = observed, binding == acknowledged,
              let worker, worker == observedWorker else { return nil }
        return VisitTicket(context: context, scope: scope, request: request, binding: binding, worker: worker)
    }
    private var permissionTicket: VisitTicket? {
        guard rootPrepared, let request, let binding = observed, binding == acknowledged, let worker else { return nil }
        return VisitTicket(context: context, scope: scope, request: request, binding: binding, worker: worker)
    }
    func needsAudioResume(_ request:UUID)->Bool {!closed && !blocked && self.request==request && audioResumeRequest==request}
    func acknowledgeWorker(_ request: UUID, receipt: PushToTalkWorkerReceipt?) {
        guard !closed, !blocked, rootPrepared, self.request == request, !initialWorkerAccepted else { return }
        initialWorkerAccepted = true
        worker = receipt?.running == true ? receipt?.generation : nil; reconcile()
    }
    func suspendSource() {
        guard !closed, !blocked else { return }
        cancelRemovalState()
        generation = UUID(); scope = UUID(); stoppedRequest = nil; editorWindow = nil; discardConfiguration(notifyWithoutWindow: true); ready = false; active = false; dirty = true
        interruptPreview(); interruptEditorWork();upgradePendingAudioToFullRetirement()
        let previous = desired; desired = nil; previous?.reply(false); kick()
    }
    func performSource(_ key: Mutation, _ action: @escaping (@escaping (PushToTalkWorkerReceipt?, Bool) -> Void) -> Void) {
        guard key != .stopSession, !closed, !blocked else { return }
        mutations[key] = .source(action); suspendSource()
    }
    func suspendForPermission() -> VisitTicket? {
        guard !closed, !blocked else { return nil }
        suspendSource(); permissionEpoch = UUID(); permission = false; return permissionTicket
    }
    func completePermission(_ ticket: VisitTicket?, allowed: Bool) {
        guard !closed, !blocked, let ticket, ticket == permissionTicket else { return }; permission = allowed
    }
    func prepareRunning(_ ticket: VisitTicket, completion: @escaping (Bool) -> Void) -> Bool {
        guard currentVisitTicket == ticket else { return false }
        ready = false; desired = Start(request: ticket.request, ticket: UUID(), renewal: true, reply: completion); kick(); return true
    }
    func activate(_ ticket: VisitTicket, options: BrowserListenerOptions, password: String) -> Bool {
        guard ready, currentVisitTicket == ticket, options.enabled else { return false }
        let accepted = backend.activate(ticket.request, binding: ticket.binding, options: options, password: password)
        guard currentVisitTicket == ticket else { return false }
        active = accepted; return accepted
    }
    struct RemovalRequest: Equatable { fileprivate let id = UUID(); let account: UUID }
    struct RemovalTicket: Equatable {
        fileprivate let request: RemovalRequest, owner: UUID, source: UUID, permission: UUID
        var account: UUID { request.account }
    }
    private final class RemovalPreparation {
        let request: RemovalRequest, reply: (RemovalTicket?) -> Void
        var cancelled = false
        init(_ request: RemovalRequest, _ reply: @escaping (RemovalTicket?) -> Void) { self.request=request; self.reply=reply }
    }
    private var removalPreparation: RemovalPreparation?, removalTicket: RemovalTicket?, reservingRemoval = false
    // This purpose grants no preview, read or save. The Root caller must first
    // prove explicit confirmed profile removal and join its window/model lifetime.
    func prepareRemoval(account: UUID, completion: @escaping (RemovalTicket?) -> Void) -> RemovalRequest? {
        guard !closed, !blocked, !delivering, !reservingRemoval, removalPreparation == nil, removalTicket == nil else { return nil }
        reservingRemoval=true; defer { reservingRemoval=false }
        let request=RemovalRequest(account:account), owner=UUID(), source=UUID()
        let previous=clear(true,replacingContext:owner,sourceScope:source)
        guard !closed, !blocked, context==owner, scope==source else {
            DispatchQueue.main.async { [weak self] in previous?.reply(false); self?.kick() }; return nil
        }
        removalPreparation=RemovalPreparation(request,completion); dirty=true
        // Construction returns before a new raw Stop can reenter the caller.
        DispatchQueue.main.async { [weak self] in previous?.reply(false); self?.kick() }
        return request
    }
    func isCurrentRemoval(_ ticket: RemovalTicket) -> Bool {
        !closed && !blocked && !dirty && !reservingRemoval && removalPreparation == nil
            && removalTicket == ticket && context == ticket.owner && scope == ticket.source
            && permissionEpoch == ticket.permission && operation == nil && preview == nil
            && jobs.isEmpty && mutations.isEmpty && desired == nil && stoppedConfigurationState
    }
    func reserveRemovalWork(_ ticket: RemovalTicket) -> EditorWork? {
        guard !delivering, editorWork == nil, isCurrentRemoval(ticket) else { return nil }
        let work=EditorWork(); editorWork=work; return work
    }
    func endRemoval(_ request: RemovalRequest) {
        if removalPreparation?.request == request { removalPreparation?.cancelled=true; kick() }
        if removalTicket?.request == request { removalTicket=nil; interruptEditorWork() }
    }
    func endRemoval(_ ticket: RemovalTicket) { endRemoval(ticket.request) }
    private func cancelRemovalState() { removalPreparation?.cancelled=true; removalTicket=nil }
    private func advanceRemovalPreparation() {
        guard let value=removalPreparation, !delivering, operation == nil, preview == nil,
              editorWork == nil, jobs.isEmpty else { return }
        if closed { guard shutdownReceipt != nil else { return } }
        else if !blocked && dirty { return }
        let accepted = !closed && !blocked && !value.cancelled && !dirty && stoppedConfigurationState
        let ticket=accepted ? RemovalTicket(request:value.request,owner:context,source:scope,permission:permissionEpoch):nil
        removalPreparation=nil; removalTicket=ticket
        delivering=true; value.reply(ticket); delivering=false
    }
    struct EditorTicket: Equatable { fileprivate let visit: VisitTicket, window: UUID, permission: UUID }
    struct ConfigurationIdentity: Equatable, Sendable {
        let account: UUID, revision: UUID
        let readOnly: Bool
    }
    fileprivate struct ConfigurationObservation: Equatable {
        let running: Bool, binding: SessionNetworkBinding?, worker: UUID?
    }
    // Session observations describe the configuration context, never native
    // admission. Keep the latest observation across retirement of native visits.
    private var configurationObservation=ConfigurationObservation(running:false,binding:nil,worker:nil)
    struct ConfigurationTicket: Equatable {
        fileprivate let identity: ConfigurationIdentity, owner: UUID, source: UUID, permission: UUID, window: UUID
        fileprivate let editor: EditorTicket?, observation: ConfigurationObservation
        var account: UUID { identity.account }
        var allowsPersistence: Bool { !identity.readOnly }
        let allowsStoppedListening: Bool
        var isRunning: Bool { editor != nil }
        var isStagedWhileRunning: Bool { editor == nil && observation.running }
    }
    enum ConfigurationApplyResult: Equatable { case staged, listening, failed }
    private var configuration: ConfigurationTicket?
    private var reservingConfiguration=false
    // Running audio needs a proved EditorTicket. A captured stopped context can
    // configure the listener alone; an unaccepted running context still stages.
    func beginConfiguration(_ identity: ConfigurationIdentity) -> ConfigurationTicket? {
        guard !reservingConfiguration else {return nil}
        reservingConfiguration=true;defer {reservingConfiguration=false}
        let before=generation,observation=configurationObservation
        let stopped = !observation.running && observation.binding == nil && backend.supportsStoppedListening
        guard configurationAdmissionReady else {return nil}
        let editor: EditorTicket?
        if currentVisitTicket != nil {
            guard let value = beginEditing() else { return nil }; editor = value
        } else {
            guard configurationOnlyState else { return nil }; discardConfiguration(); editor = nil
        }
        guard generation==before,configurationObservation==observation,configurationAdmissionReady else {return nil}
        let value = ConfigurationTicket(identity: identity, owner: context, source: scope,
            permission: permissionEpoch, window: UUID(), editor: editor,observation:observation,allowsStoppedListening:stopped)
        configuration = value
        guard isCurrentConfiguration(value) else { configuration = nil; return nil }
        return value
    }
    private func discardConfiguration(notifyWithoutWindow: Bool = false, audioOnly: Bool = false) {
        guard configuration != nil || notifyWithoutWindow else { return }
        configuration = nil
        if audioOnly {onAudioConfigurationInvalidated?()} else {onConfigurationInvalidated?()}
    }
    private var configurationAdmissionReady: Bool {
        !closed && !blocked && !reservingRemoval && removalPreparation == nil && removalTicket == nil
            && !dirty && !delivering && operation == nil && preview == nil
            && editorWork == nil && jobs.isEmpty && mutations.isEmpty && desired == nil
    }
    private var configurationOnlyState: Bool {
        !rootPrepared && !ready && (!active || stoppedRequest != nil) && request == nil && acknowledged == nil
            && applied == nil && worker == nil && (configurationObservation.running || configurationObservation.binding == nil)
            && (backend.listenerState == .off || stoppedRequest != nil)
    }
    private var stoppedConfigurationState: Bool {
        !rootPrepared && !ready && !active && request == nil && acknowledged == nil && observed == nil
            && applied == nil && worker == nil && observedWorker == nil && stoppedRequest == nil && backend.listenerState == .off
    }
    // A new profile value may replace only a fully retired visit. Rotating its
    // opaque context needs no new native Stop, factory, timer or failure book.
    func renewRetiredProfileContext() -> Bool {
        let before=generation
        guard profileContextRetired,generation==before else {return false}
        let owner=UUID(),source=UUID()
        let previous=clear(true,replacingContext:owner,sourceScope:source)
        previous?.reply(false)
        let after=generation
        return profileContextRetired && generation==after && context==owner && scope==source
    }
    // Completed permanent retirement permits local profile persistence while a
    // failed later shutdown keeps the App open; it never reopens native authority.
    var profilePersistenceRetired: Bool {
        if case .success?=terminal {return true}
        // A running audio observation is not browser authority. Once browser
        // work has retired, it must not prevent saving the current audio profile.
        return profileWorkRetired && configurationOnlyState && stoppedRequest == nil
    }
    private var profileWorkRetired: Bool {
        !closed && !blocked && !dirty && !delivering && !reservingRemoval && !reservingConfiguration && removalPreparation == nil
            && removalTicket == nil && operation == nil && preview == nil && editorWork == nil
            && configuration == nil && editorWindow == nil && desired == nil && jobs.isEmpty
            && mutations.isEmpty
    }
    var profileContextRetired: Bool { profileWorkRetired && stoppedConfigurationState }
    func isCurrentConfiguration(_ ticket: ConfigurationTicket) -> Bool {
        guard !closed, !blocked, !dirty, jobs.isEmpty, mutations.isEmpty, configuration == ticket,
              context == ticket.owner, scope == ticket.source, permissionEpoch == ticket.permission else { return false }
        if let editor = ticket.editor { return isCurrentEditor(editor) }
        let before=generation
        let valid=(operation == nil || preview?.configuration == ticket) && desired == nil && configurationObservation==ticket.observation && configurationOnlyState
        return valid && generation==before && configuration==ticket && configurationObservation==ticket.observation
    }
    func reserveConfigurationWork(_ ticket: ConfigurationTicket) -> EditorWork? {
        guard !reservingConfiguration, editorWork == nil, preview == nil, operation == nil, desired == nil,
              !delivering, isCurrentConfiguration(ticket) else { return nil }
        let value = EditorWork(); editorWork = value; return value
    }
    func endConfiguration(_ ticket: ConfigurationTicket) {
        guard configuration == ticket,!reservingConfiguration else { return }
        reservingConfiguration=true;defer{reservingConfiguration=false}
        configuration=nil;backend.cancelAddressRefresh()
        if let editor = ticket.editor { endEditing(editor) }
        interruptEditorWork()
    }
    func apply(_ choice: BrowserListenerChoice, configuration ticket: ConfigurationTicket,
               completion: @escaping (ConfigurationApplyResult) -> Void) -> Bool {
        guard !reservingConfiguration, isCurrentConfiguration(ticket), BrowserListenerEdit.fits(choice.password),
              !choice.options.enabled || !choice.password.isEmpty else { return false }
        if let editor = ticket.editor {
            return apply(choice, editor: editor) { [weak self] success in
                let current = self?.isCurrentConfiguration(ticket) == true
                completion(success && current ? (choice.options.enabled ? .listening : .staged) : .failed)
            }
        }
        if ticket.allowsStoppedListening {
            guard preview == nil, editorWork == nil, operation == nil, desired == nil, !delivering else {return false}
            let value=Preview(ticket,choice) { success in completion(success ? (choice.options.enabled ? .listening:.staged):.failed) }
            stoppedRequest=value.request;preview=value;ready=false;active=false
            runPreview(value,choice.options.enabled ? .prepare:.stop);return true
        }
        guard let work = reserveConfigurationWork(ticket) else { return false }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            _ = self.completeEditorWork(work) { [weak self] in
                completion(self?.isCurrentConfiguration(ticket) == true ? .staged : .failed)
            }
        }
        return true
    }

    private var addressWork: (ticket: ConfigurationTicket, work: EditorWork)?
    func canQueryAddress(_ ticket: ConfigurationTicket) -> Bool {
        guard ticket.isRunning || (ticket.allowsStoppedListening && stoppedRequest != nil && active),
              isCurrentConfiguration(ticket), backend.listenerState == .listening else { return false }
        return isCurrentConfiguration(ticket)
    }
    func refreshAddress(configuration ticket: ConfigurationTicket, completion: @escaping (BrowserListenerAddressResult) -> Void) -> Bool {
        guard canQueryAddress(ticket), let work = reserveConfigurationWork(ticket) else { return false }
        addressWork = (ticket, work)
        let receipt = Receipt()
        receipt.admitted = backend.refreshAddress { [weak self] result in
            guard receipt.claim() else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, receipt.admitted else { return }
                _ = self.completeEditorWork(work) { [weak self] in
                    guard let self else { return }; self.addressWork = nil
                    completion(self.isCurrentConfiguration(ticket) ? result : .cancelled)
                }
            }
        }
        if !receipt.admitted { finishRefusedAddress(work) }
        return receipt.admitted
    }
    func reviewPublicAccess(configuration ticket: ConfigurationTicket, completion: @escaping (BrowserListenerFunnelReviewResult) -> Void) -> Bool {
        guard canQueryAddress(ticket), let work = reserveConfigurationWork(ticket) else { return false }
        addressWork = (ticket, work)
        let receipt = Receipt()
        receipt.admitted = backend.reviewPublicAccess { [weak self] result in
            guard receipt.claim() else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, receipt.admitted else { return }
                _ = self.completeEditorWork(work) { [weak self] in
                    guard let self else { return }; self.addressWork = nil
                    completion(self.isCurrentConfiguration(ticket) ? result : .cancelled)
                }
            }
        }
        if !receipt.admitted { finishRefusedAddress(work) }
        return receipt.admitted
    }
    func copyAddress(_ value: BrowserListenerAddress, configuration ticket: ConfigurationTicket, completion: @escaping (String?) -> Void) -> Bool {
        guard canQueryAddress(ticket), let work = reserveConfigurationWork(ticket) else { return false }
        addressWork = (ticket, work)
        let receipt = Receipt()
        receipt.admitted = backend.copyAddress(value) { [weak self] text in
            guard receipt.claim() else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, receipt.admitted else { return }
                _ = self.completeEditorWork(work) { [weak self] in
                    guard let self else { return }; self.addressWork = nil
                    completion(self.isCurrentConfiguration(ticket) ? text : nil)
                }
            }
        }
        if !receipt.admitted { finishRefusedAddress(work) }
        return receipt.admitted
    }
    func turnOnPublicAccess(configuration ticket: ConfigurationTicket, completion: @escaping (BrowserListenerFunnelResult) -> Void) -> Bool {
        guard canQueryAddress(ticket), let work=reserveConfigurationWork(ticket) else {return false}
        addressWork=(ticket,work);let receipt=Receipt()
        receipt.admitted=backend.turnOnPublicAccess { [weak self] result in
            guard receipt.claim() else {return}
            DispatchQueue.main.async { [weak self] in
                guard let self,receipt.admitted else {return}
                _ = self.completeEditorWork(work) { [weak self] in
                    guard let self else {return};self.addressWork=nil
                    completion(self.isCurrentConfiguration(ticket) ? result:.cancelled)
                }
            }
        }
        if !receipt.admitted {finishRefusedAddress(work)};return receipt.admitted
    }
    private func finishRefusedAddress(_ work: EditorWork) {
        // False admitted no lower callback work. A reentrant invalidation still
        // keeps this same credit until its independent Stop receipt arrives.
        _ = completeEditorWork(work) { [weak self] in self?.addressWork = nil }
    }
    func cancelAddressQuery(configuration ticket: ConfigurationTicket) {
        if let pending=addressWork {guard pending.ticket==ticket else {return}}
        else {guard isCurrentConfiguration(ticket) else {return}}
        // Cancel only the child query. Context loss separately joins Core Stop;
        // an ordinary Cancel/OK must first wait this same raw-work credit.
        backend.cancelAddressRefresh()
    }

    // Only the locked borrow flag crosses queues. Receipt fields stay on this MainActor.
    final class EditorWork: @unchecked Sendable {
        private let lock = NSLock(); private var live = true
        fileprivate var interrupted = false, retirementPending = false, returned = false
        fileprivate var audioRetirementRequested=false,fullRetirementRequested=false,pendingRetirements=0
        fileprivate var delivery: (() -> Void)?
        fileprivate init() {}
        var mayBorrow: Bool { lock.lock(); defer { lock.unlock() }; return live }
        fileprivate func revoke() { lock.lock(); live = false; lock.unlock() }
    }
    private var editorWork: EditorWork?
    func reserveEditorWork(_ ticket: EditorTicket) -> EditorWork? {
        guard editorWork == nil, preview == nil, operation == nil, desired == nil, !delivering, isCurrentEditor(ticket) else { return nil }
        let value = EditorWork(); editorWork = value; return value
    }
    // This is a raw-work return receipt; actual delivery may still wait Core Stop.
    func completeEditorWork(_ work: EditorWork, completion: @escaping () -> Void) -> Bool {
        guard editorWork === work, !work.returned else { return false }
        work.returned = true; work.revoke(); work.delivery = completion; finishEditorWork(work); return true
    }
    private func interruptEditorWork(audioOnly:Bool=false) {
        guard let work=editorWork else {return}
        if work.interrupted {guard !audioOnly,work.audioRetirementRequested,!work.fullRetirementRequested else {return}}
        work.interrupted=true;work.revoke()
        if audioOnly {work.audioRetirementRequested=true} else {work.fullRetirementRequested=true}
        // At most one source-only receipt and its independent full-context upgrade.
        work.pendingRetirements += 1;work.retirementPending=true
        let receipt = Receipt()
        let retired:()->Void = { [weak self] in
            guard receipt.claim() else {return}
            DispatchQueue.main.async { [weak self] in
                guard receipt.admitted else {return};self?.editorWorkRetired(work,true)
            }
        }
        if audioOnly {receipt.admitted=backend.prepareAudioTransition(UUID()){_ in retired()}}
        else {receipt.admitted=backend.stop(completion:retired)}
        if !receipt.admitted { DispatchQueue.main.async { [weak self] in self?.editorWorkRetired(work, false) } }
    }
    private func editorWorkRetired(_ work: EditorWork, _ admitted: Bool) {
        guard editorWork === work,work.pendingRetirements>0 else {return}
        work.pendingRetirements -= 1;work.retirementPending=work.pendingRetirements>0
        if !admitted { blocked = true; let previous = clear(true); previous?.reply(false); onFailure?() }
        finishEditorWork(work)
    }
    private func finishEditorWork(_ work: EditorWork) {
        guard editorWork === work, work.returned, !work.retirementPending, let delivery = work.delivery else { return }
        editorWork = nil; work.delivery = nil; delivering = true
        delivery(); delivering = false
        finishShutdownIfPossible(); kick()
    }
    private enum PreviewStage { case prepare, activate, stop }
    private final class Preview {
        let ticket: EditorTicket?, configuration: ConfigurationTicket?, request: UUID, binding: SessionNetworkBinding?
        let options: BrowserListenerOptions, reply: (Bool) -> Void
        var password: String?, pending: UUID?, result: Bool?
        var interrupted = false, retirementPending = false
        init(_ ticket: EditorTicket, _ choice: BrowserListenerChoice, _ reply: @escaping (Bool) -> Void) {
            self.ticket = ticket; configuration=nil;request=ticket.visit.request;binding=ticket.visit.binding
            options = choice.options; password = choice.password; self.reply = reply
        }
        init(_ ticket:ConfigurationTicket,_ choice:BrowserListenerChoice,_ reply:@escaping(Bool)->Void) {
            self.ticket=nil;configuration=ticket;request=UUID();binding=nil
            options=choice.options;password=choice.password;self.reply=reply
        }
    }
    private var stoppedRequest: UUID?
    private func previewCurrent(_ value: Preview) -> Bool {
        if let ticket=value.ticket {return isCurrentEditor(ticket)}
        guard let ticket=value.configuration, ticket.allowsStoppedListening, stoppedRequest==value.request else {return false}
        return isCurrentConfiguration(ticket)
    }
    private var editorWindow: UUID?, preview: Preview?
    func beginEditing() -> EditorTicket? {
        guard preview == nil, let ticket = currentVisitTicket else { return nil }
        discardConfiguration()
        let window = UUID(); editorWindow = window
        return EditorTicket(visit: ticket, window: window, permission: permissionEpoch)
    }
    func isCurrentEditor(_ ticket: EditorTicket) -> Bool {
        // Own prepare/Stop may temporarily remove the public renewable visit. It
        // does not change the root, worker, source, permission or window identities.
        guard !closed, !blocked, rootPrepared, permission, !dirty, jobs.isEmpty, mutations.isEmpty,
              editorWindow == ticket.window, permissionEpoch == ticket.permission,
              context == ticket.visit.context, scope == ticket.visit.scope,
              request == ticket.visit.request, observed == ticket.visit.binding, acknowledged == observed,
              worker == ticket.visit.worker, observedWorker == worker else { return false }
        return true
    }
    func endEditing(_ ticket: EditorTicket) {
        guard editorWindow == ticket.window else { return }
        editorWindow = nil; discardConfiguration(); interruptPreview(); interruptEditorWork()
    }
    // One bounded preview, with no raw callback on refusal. Core retains all native
    // authorities; this owner joins its completion and independent invalidation Stop.
    func apply(_ choice: BrowserListenerChoice, editor: EditorTicket, completion: @escaping (Bool) -> Void) -> Bool {
        guard preview == nil, editorWork == nil, operation == nil, desired == nil, !delivering, isCurrentEditor(editor),
              BrowserListenerEdit.fits(choice.password), !choice.options.enabled || !choice.password.isEmpty else { return false }
        let value = Preview(editor, choice, completion); preview = value
        ready = false; active = false
        runPreview(value, choice.options.enabled ? .prepare : .stop); return true
    }
    private func runPreview(_ value: Preview, _ stage: PreviewStage) {
        let id = UUID(), receipt = Receipt(); value.pending = id; operation = id
        let reply: (Bool) -> Void = { [weak self] applied in
            guard receipt.claim() else { return }
            DispatchQueue.main.async { [weak self] in
                guard receipt.admitted else { return }; self?.previewReceived(value, id, stage, applied)
            }
        }
        switch stage {
        case .prepare: receipt.admitted = backend.prepareStart(value.request, completion: reply)
        case .stop: receipt.admitted = backend.stop { reply(true) }
        case .activate:
            guard previewCurrent(value), !value.interrupted, let password = value.password else {
                value.password = nil; previewReceived(value, id, stage, false); return
            }
            let completed:(BrowserListenerActivationResult)->Void = { result in
                if case .listening(let port)=result {reply(port>0)} else {reply(false)}
            }
            if let binding=value.binding {
                receipt.admitted=backend.activate(value.request,binding:binding,options:value.options,password:password,completion:completed)
            } else {
                receipt.admitted=backend.activateStopped(value.request,options:value.options,password:password,completion:completed)
            }
            value.password = nil
            active = receipt.admitted && !value.interrupted && previewCurrent(value)
        }
        if !receipt.admitted { DispatchQueue.main.async { [weak self] in self?.previewReceived(value, id, stage, false) } }
    }
    private func previewReceived(_ value: Preview, _ id: UUID, _ stage: PreviewStage, _ applied: Bool) {
        guard preview === value, value.pending == id else { return }
        value.pending = nil; if operation == id { operation = nil }
        if stage == .prepare, applied, !value.interrupted, previewCurrent(value) {
            runPreview(value, .activate); return
        }
        value.password = nil
        value.result = applied && !value.interrupted && previewCurrent(value)
        active = stage == .activate && value.result == true
        finishPreview(value)
    }
    private func interruptPreview() {
        guard let value = preview, !value.interrupted else { return }
        value.interrupted = true; value.password = nil; active = false; ready = false
        value.retirementPending = true
        let receipt = Receipt()
        receipt.admitted = backend.stop { [weak self] in
            guard receipt.claim() else { return }
            DispatchQueue.main.async { [weak self] in
                guard receipt.admitted else { return }; self?.previewRetired(value, true)
            }
        }
        if !receipt.admitted { DispatchQueue.main.async { [weak self] in self?.previewRetired(value, false) } }
    }
    private func previewRetired(_ value: Preview, _ admitted: Bool) {
        guard preview === value else { return }
        value.retirementPending = false
        if !admitted { blocked = true; let previous = clear(true); previous?.reply(false); onFailure?() }
        finishPreview(value)
    }
    private func finishPreview(_ value: Preview) {
        guard preview === value, value.pending == nil, !value.retirementPending, let result = value.result else { return }
        let applied = result && !value.interrupted && previewCurrent(value)
        preview = nil; value.password = nil
        if applied, !value.options.enabled, value.configuration != nil {stoppedRequest=nil}
        value.reply(applied)
        finishShutdownIfPossible(); kick()
    }
    private let backend: BrowserSessionBackend
    private struct Start {
        let request:UUID,ticket:UUID,renewal:Bool,reply:(Bool)->Void,audioOnly:Bool
        init(request:UUID,ticket:UUID,renewal:Bool,reply:@escaping(Bool)->Void,audioOnly:Bool=false) {self.request=request;self.ticket=ticket;self.renewal=renewal;self.reply=reply;self.audioOnly=audioOnly}
    }
    private enum Work { case stop, audioStop(UUID), prepare(Start), attachAudio(VisitTicket), shutdown }
    private enum Change {
        case immediate(() -> Void)
        case source((@escaping (PushToTalkWorkerReceipt?, Bool) -> Void) -> Void)
    }
    private final class Receipt {
        private let lock = NSLock(); private var taken = false
        var admitted = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; guard !taken else { return false }; taken = true; return true }
    }
    private var audioStopRequest:UUID?,audioResumeRequest:UUID?,audioOperation:UUID?,audioUpgradedOperation:UUID?
    private var desired: Start?, request: UUID?, acknowledged: SessionNetworkBinding?, observed: SessionNetworkBinding?, applied: SessionNetworkBinding?
    private var worker: UUID?, observedWorker: UUID?
    private var rootPrepared = false, permission = true
    private var permissionEpoch = UUID(), active = false, initialWorkerAccepted = false
    private var context = UUID(), scope = UUID()
    private var ready = false, closed = false, blocked = false, dirty = false, delivering = false
    private var generation = UUID(), operation: UUID?, shutdownStarted = false
    private var mutations = [Mutation: Change](), waiters = [(Result<Void, Error>) -> Void]()
    private var jobs = Set<UUID>(), latestJob: UUID?, latestReceipt: (UUID, UUID, PushToTalkWorkerReceipt?, Bool)?
    private var shutdownReceipt: Result<Void, Error>?
    private var terminal: Result<Void, Error>?
    init(backend: BrowserSessionBackend) { self.backend = backend }
    private func clear(_ discard: Bool, replacingContext: UUID = UUID(), sourceScope: UUID = UUID(), audioOnly: Bool = false) -> Start? {
        generation = UUID(); let previous = desired; desired = nil;audioStopRequest=nil;audioResumeRequest=nil
        cancelRemovalState()
        context = replacingContext; scope = sourceScope; rootPrepared = false; permission = true; worker = nil; observedWorker = nil
        permissionEpoch = UUID(); active = false; initialWorkerAccepted = false
        request = nil; stoppedRequest = nil; ready = false; acknowledged = nil; observed = nil; applied = nil
        editorWindow = nil; discardConfiguration(notifyWithoutWindow: true,audioOnly:audioOnly); interruptPreview(); interruptEditorWork(audioOnly:audioOnly)
        if !audioOnly {upgradePendingAudioToFullRetirement()}
        if discard { mutations.removeAll() }
        return previous
    }
    func beforeAudioStart(_ request: UUID, completion: @escaping (Bool) -> Void) -> Bool {
        guard backend.supportsAudioContinuity else {return beforeStart(request,completion:completion)}
        guard !closed,!blocked else {return false}
        let owner=context,source=UUID()
        let previous=clear(false,replacingContext:owner,sourceScope:source,audioOnly:true)
        guard !closed,!blocked,context==owner,scope==source else {previous?.reply(false);kick();return false}
        let next=Start(request:request,ticket:UUID(),renewal:false,reply:completion,audioOnly:true)
        desired=next;self.request=request;previous?.reply(false);kick();return true
    }
    func performAudioStop(_ action: @escaping () -> Void) {
        guard backend.supportsAudioContinuity else {perform(.stopSession,action);return}
        guard !closed,!blocked else {return}
        let owner=context,source=UUID()
        let previous=clear(true,replacingContext:owner,sourceScope:source,audioOnly:true)
        guard !closed,!blocked,context==owner,scope==source else {previous?.reply(false);kick();return}
        dirty=true;audioStopRequest=UUID();mutations[.stopSession] = .immediate(action);previous?.reply(false);kick()
    }
    func beforeStart(_ request: UUID, completion: @escaping (Bool) -> Void) -> Bool {
        guard !closed, !blocked else { return false }
        let previous = clear(false)
        let next = Start(request: request, ticket: UUID(), renewal: false, reply: completion)
        desired = next; self.request = request
        previous?.reply(false); kick(); return true
    }
    func invalidate(discardMutations: Bool = false) {
        guard !closed, !blocked else { return }
        let previous = clear(discardMutations); dirty = true
        previous?.reply(false); kick()
    }
    func perform(_ key: Mutation, _ action: @escaping () -> Void) {
        guard !closed, !blocked else { return }
        let previous = clear(key == .stopSession); dirty = true; mutations[key] = .immediate(action)
        previous?.reply(false); kick()
    }
    private func reserveAudioOperation(_ id:UUID) {jobs.insert(id);audioOperation=id;audioUpgradedOperation=nil}
    private func upgradePendingAudioToFullRetirement() {
        guard !closed,!blocked,let audioOperation,audioUpgradedOperation != audioOperation else {return}
        audioUpgradedOperation=audioOperation
        let id=UUID(),receipt=Receipt();jobs.insert(id)
        // Context loss revokes native Room admission now, even if an earlier
        // source-only callback or its MainActor delivery has not returned.
        receipt.admitted=backend.stop { [weak self] in
            guard receipt.claim() else {return}
            DispatchQueue.main.async { [weak self] in
                guard let self,receipt.admitted,self.jobs.remove(id) != nil else {return}
                self.finishShutdownIfPossible();self.kick()
            }
        }
        if !receipt.admitted {DispatchQueue.main.async { [weak self] in
            guard let self,self.jobs.remove(id) != nil else {return}
            self.blocked=true;let previous=self.clear(true);previous?.reply(false);self.onFailure?();self.finishShutdownIfPossible()
        }}
    }
    private func kick() {
        guard !delivering, operation == nil, preview == nil, editorWork == nil, jobs.isEmpty else { return }
        advanceRemovalPreparation()
        guard !closed, !blocked, removalTicket == nil else { return }
        if dirty || !mutations.isEmpty { if let audioStopRequest,mutations.count==1,mutations[.stopSession] != nil {begin(.audioStop(audioStopRequest))} else {begin(.stop)} }
        else if let desired { begin(.prepare(desired)) }
    }
    private func begin(_ work: Work) {
        let id = UUID(), receipt = Receipt(); operation = id
        let reply: (Bool) -> Void = { [weak self] value in
            guard receipt.claim() else { return }
            // The locked first receipt is marshalled even when an injected provider
            // calls inline or on a foreign thread. Admission is inspected after return.
            DispatchQueue.main.async { [weak self] in
                guard receipt.admitted else { return }; self?.finished(id, work, value)
            }
        }
        switch work {
        case .stop: receipt.admitted = backend.stop { reply(true) }
        case .prepare(let start):
            if start.audioOnly {reserveAudioOperation(id);receipt.admitted=backend.prepareAudioTransition(start.request,completion:reply)}
            else {receipt.admitted=backend.prepareStart(start.request,completion:reply)}
        case .audioStop(let request):reserveAudioOperation(id);receipt.admitted=backend.prepareAudioTransition(request,completion:reply)
        case .attachAudio(let ticket):reserveAudioOperation(id);receipt.admitted=backend.attachAudio(ticket.request,binding:ticket.binding,completion:reply)
        case .shutdown: receipt.admitted = backend.shutdown { reply(true) }
        }
        if !receipt.admitted {
            DispatchQueue.main.async { [weak self] in self?.refused(id, work) }
        }
    }
    private func refused(_ id: UUID, _ work: Work) {
        jobs.remove(id);if audioOperation==id {audioOperation=nil}
        guard operation == id else {finishShutdownIfPossible();kick();return};operation=nil
        if case .prepare(let start)=work,start.audioOnly,desired?.ticket != start.ticket {kick();return}
        if case .audioStop(let request)=work,audioStopRequest != request {kick();return}
        if case .attachAudio=work {invalidate(discardMutations:true);onListenerFailure?();return}
        blocked=true
        let previous = clear(true); previous?.reply(false); onFailure?()
        if case .shutdown = work { shutdownReceipt = .failure(Failure.retirementRefused) }
        advanceRemovalPreparation(); finishShutdownIfPossible()
    }
    private func finished(_ id: UUID, _ work: Work, _ accepted: Bool) {
        jobs.remove(id);if audioOperation==id {audioOperation=nil}
        guard operation == id else {finishShutdownIfPossible();kick();return};operation=nil
        switch work {
        case .shutdown: shutdownReceipt = .success(()); finishShutdownIfPossible(); return
        case .prepare(let start):
            guard desired?.ticket == start.ticket, !dirty, mutations.isEmpty else { kick(); return }
            let epoch=generation
            let retained=start.audioOnly && backend.listenerState == .listening
            guard desired?.ticket==start.ticket,generation==epoch,!dirty else {kick();return}
            desired = nil; ready = accepted
            if start.audioOnly {audioResumeRequest=accepted && retained ? start.request:nil;if !retained {onConfigurationInvalidated?()}}
            if !start.renewal { rootPrepared = accepted }
            if !accepted { blocked = true; _ = clear(true); onFailure?() }
            start.reply(accepted);reconcile()
        case .attachAudio(let ticket):
            guard currentVisitTicket==ticket else {kick();return}
            if accepted {active=true} else {invalidate(discardMutations:true);onListenerFailure?()}
        case .stop,.audioStop(_):
            if case .audioStop(let request)=work {
                guard audioStopRequest==request,!closed,!blocked else {kick();return}
                guard accepted else {blocked=true;_ = clear(true);onFailure?();return}
                let epoch=generation,retained=backend.listenerState == .listening
                guard !closed,!blocked,generation==epoch,audioStopRequest==request else {kick();return}
                stoppedRequest=request;active=retained
                if !active {stoppedRequest=nil;onConfigurationInvalidated?()}
                audioStopRequest=nil
            }
            dirty = false
            let batch = mutations; mutations.removeAll(); let ticket = generation; delivering = true
            for key in Mutation.allCases {
                guard !closed, !blocked, ticket == generation else { break }
                switch batch[key] {
                case .immediate(let action): action()
                case .source(let action): submitSource(action)
                case nil: break
                }
            }
            delivering = false
        }
        kick()
    }
    private func submitSource(_ action: (@escaping (PushToTalkWorkerReceipt?, Bool) -> Void) -> Void) {
        let id = UUID(), owner = context, permission = permissionEpoch, receipt = Receipt()
        jobs.insert(id); latestJob = id; latestReceipt = nil
        action { [weak self] value, allowed in
            guard receipt.claim() else { return }
            DispatchQueue.main.async { [weak self] in self?.sourceFinished(id, context: owner, permission: permission, receipt: value, allowed: allowed) }
        }
    }
    private func sourceFinished(_ id: UUID, context owner: UUID, permission epoch: UUID, receipt: PushToTalkWorkerReceipt?, allowed: Bool) {
        guard jobs.remove(id) != nil else { return }
        if owner == context, id == latestJob { latestReceipt = (owner, epoch, receipt, allowed) }
        guard jobs.isEmpty else { return }
        // Submission order is the Session worker order; callback arrival is not.
        if let (owner, epoch, receipt, allowed) = latestReceipt, owner == context, !closed {
            worker = receipt?.running == true ? receipt?.generation : nil; initialWorkerAccepted = true
            // A source callback may finish after a newer permission decision.
            if epoch == permissionEpoch { permission = allowed }
        }
        latestReceipt = nil; latestJob = nil; finishShutdownIfPossible(); kick()
    }
    func observe(running: Bool, binding: SessionNetworkBinding?, workerGeneration: UUID? = nil) {
        guard !closed, !blocked else { return }
        configurationObservation = .init(running:running,binding:binding,worker:running ? workerGeneration:nil)
        refreshFailure()
        // Repeated observations keep configuration-only editing stable. A new
        // binding, worker or running state revokes it before any further borrow.
        if let configuration, configuration.editor == nil, configuration.observation != configurationObservation {
            invalidate(discardMutations: true); return
        }
        let value = running ? binding : nil
        if let applied, applied != value { invalidate(discardMutations: true); return }
        if let worker, observedWorker == worker, workerGeneration != worker,
           !dirty, jobs.isEmpty, mutations.isEmpty {
            suspendSource(); self.worker = nil
        }
        observed = value; observedWorker = running ? workerGeneration : nil; reconcile()
    }
    func acknowledgeStart(_ request: UUID, binding: SessionNetworkBinding?) {
        guard !closed, !blocked, rootPrepared, self.request == request else { return }
        guard let binding, binding.port > 0 else { invalidate(discardMutations: true); return }
        acknowledged = binding; reconcile()
    }
    private func reconcile() {
        if rootPrepared, request != nil, let observed, observed == acknowledged { applied = observed }
        if let ticket=currentVisitTicket,audioResumeRequest==ticket.request {
            audioResumeRequest=nil;begin(.attachAudio(ticket))
        }
    }
    func activate(options: BrowserListenerOptions, password: String) -> Bool {
        guard let ticket = currentVisitTicket else { return false }; return activate(ticket, options: options, password: password)
    }
    func shutdown(_ completion: @escaping (Result<Void, Error>) -> Void) -> Bool {
        guard waiters.count < Self.maximumWaiters else { return false }
        if let terminal { completion(terminal); return true }
        waiters.append(completion)
        guard !shutdownStarted else { return true }; shutdownStarted = true; closed = true
        let previous = clear(true); previous?.reply(false)
        // Upgrade immediately, even if an old Stop/prepare callback is still queued.
        // Its ticket cannot complete this distinct permanent shutdown barrier.
        begin(.shutdown); return true
    }
    private func finishShutdownIfPossible() {
        advanceRemovalPreparation()
        guard removalPreparation == nil, terminal == nil, !delivering, preview == nil, editorWork == nil, jobs.isEmpty, let result = shutdownReceipt else { return }
        terminal = result; let callbacks = waiters; waiters.removeAll()
        for callback in callbacks { callback(result) }
    }
    deinit { MainActor.assumeIsolated { preview?.password = nil; editorWork?.revoke(); _ = backend.shutdown {} } }
}
