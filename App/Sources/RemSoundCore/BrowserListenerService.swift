import Foundation
import RemSoundJam
import RemSoundRuntime

public struct BrowserListenerOptions: Equatable, Sendable {
    public let enabled: Bool, autoStart: Bool
    /// autoStart permits the shared page to remember the password in that browser's localStorage.
    public init(enabled: Bool = false, autoStart: Bool = false) { self.enabled = enabled; self.autoStart = autoStart }
}

/// A local configuration receipt, not continuing listener health or remote delivery.
public enum BrowserListenerActivationResult: Equatable, Sendable {
    case listening(port: UInt16)
    case unavailable
    case cancelled
}

public struct BrowserListenerStatus: Equatable, Sendable {
    public enum State: Equatable, Sendable { case off, preparing, starting, listening, unavailable, stopping, closed }
    public let state: State, boundPort: UInt16?, sourceAttached: Bool, retiring: Bool
}

/// An exclusive listener lifetime. Construct after application runtime preparation. Completion callbacks
/// run on its utility queue; callers marshal UI work to the main queue. False admits no callback.
public final class BrowserListenerService {
    private let owner: WebBrowserOwner
    public convenience init(runtime: RuntimeConfiguration, session: Session) {
        let queue = DispatchQueue(label: "RemSound browser listener", qos: .utility)
        self.init(queue: queue, isolated: runtime.isIsolated, dependencies: .native(runtime, session))
    }
    internal init(queue: DispatchQueue, isolated: Bool, dependencies: WebBrowserDependencies) {
        owner = WebBrowserOwner(queue, isolated, dependencies); owner.assemble()
    }
    public var status: BrowserListenerStatus { owner.status }
    #if DEBUG
    // Read-only protocol receipts for owned integration tests; no transport or credential authority.
    func testPeerReports() -> [WebPeer.Report] { owner.testPeerReports() }
    #endif
    /// Admission only; false promises no callback. Current Session observations
    /// and the actual listener port are reproved without borrowing a password.
    public func refreshAddress(completion: @escaping (BrowserListenerAddressResult) -> Void) -> Bool { owner.refreshAddress(completion) }
    /// Uses only fixed readonly status queries. False admits no callback.
    public func reviewPublicAccess(completion: @escaping (BrowserListenerFunnelReviewResult) -> Void) -> Bool { owner.reviewPublicAccess(completion) }
    /// Explicitly run the fixed Funnel command for this listener. Printed approval
    /// pages may open while it waits. Effects can persist after cancellation.
    public func turnOnPublicAccess(completion: @escaping (BrowserListenerFunnelResult) -> Void) -> Bool { owner.turnOnPublicAccess(completion) }
    /// Revoke pending status/approval work and idle receipts, preserving a current listener.
    public func cancelAddressRefresh() { owner.cancelAddress() }
    /// Re-prove this service's current receipt and Session binding before an explicit copy.
    /// The string is a local historical configuration observation, not reachability.
    public func copyAddress(_ value: BrowserListenerAddress, completion: @escaping (String?) -> Void) -> Bool { owner.copyAddress(value, completion) }
    /// Call before changing the Session request, profile, permission or audio options.
    /// True completion means the old source, room and admitted callbacks have retired,
    /// and this is still the newest request. It does not start the Session or listener.
    public func prepareStart(_ request: UUID, completion: @escaping (Bool) -> Void) -> Bool { owner.prepare(request, completion) }
    /// Retire only the current audio source within the unchanged listener context.
    /// Full stop/prepareStart/shutdown still join Room and every native callback.
    public func prepareAudioTransition(_ request: UUID, completion: @escaping (Bool) -> Void) -> Bool { owner.prepareAudio(request, completion) }
    /// Attach the newest prepared audio request after the actual worker/socket is observed.
    /// This does not create a listener or load a password. False admits no callback.
    public func attachAudio(_ request: UUID, binding: SessionNetworkBinding, completion: @escaping (Bool) -> Void) -> Bool { owner.attachAudio(request,binding,completion) }

    /// Admission only. The actual Session worker must re-prove this binding. A listening
    /// status additionally requires native bind and worker attachment receipts, not remote delivery.
    public func activate(_ request: UUID, binding: SessionNetworkBinding, options: BrowserListenerOptions, password: String) -> Bool {
        owner.activate(request, binding, options, password)
    }
    /// False admits no callback. Listening requires the current native bind and actual
    /// worker attachment. Failure or cancellation completes only after full retirement.
    public func activate(_ request: UUID, binding: SessionNetworkBinding, options: BrowserListenerOptions, password: String,
                         completion: @escaping (BrowserListenerActivationResult) -> Void) -> Bool {
        owner.activate(request, binding, options, password, completion)
    }
    /// Requires the newest prepared request and an actual stopped Session observation.
    /// Listening confirms native bind only; sourceAttached remains false. This never
    /// starts Session or attaches audio. False admits no callback; failure/cancellation
    /// joins actual Room and observation retirement before completion.
    public func activateStopped(_ request: UUID, options: BrowserListenerOptions, password: String,
                                completion: @escaping (BrowserListenerActivationResult) -> Void) -> Bool { owner.activate(request, nil, options, password, completion) }
    public func stop(completion: @escaping () -> Void) -> Bool { owner.close(false, completion) }
    /// Each browser listening, in Windows' words ("Browser 1: Opus, stream 3: buffer ...."), on the main queue.
    public func describeBrowsers(reply: @escaping ([String]) -> Void) { owner.describeBrowsers(reply) }
    public func shutdown(completion: @escaping () -> Void) -> Bool { owner.close(true, completion) }
    deinit { _ = owner.close(true, nil) }
}

// Test seams and raw authorities never cross the Core boundary.
struct WebBrowserDependencies {
    var observe: (@escaping (SessionNetworkBinding?) -> Void) -> Bool
    var revoke: () -> Void
    var attach: (WebAudioHandoff.Producer, @escaping (Bool) -> Void) -> Bool
    var page: () -> Data?
    var credential: (String) -> WebAuthentication.Credential?
    var listener: (DispatchQueue, @escaping () -> Bool, @escaping (UInt16) -> Void) -> WebRoom.Listener?
    var clock: () -> Double
    var admissionSchedule: (@escaping () -> Bool) -> WebConnection.Schedule
    var peerSchedule: (@escaping () -> Bool) -> WebConnection.Schedule
    var addressQuery:WebFunnelQuery.Launch = {_,_ in nil}
    var scopedAddressQuery: ((@escaping()->Bool)->WebFunnelQuery.Launch)?
    var addressPermission: ((WebAudioHandoff.Binding)->Bool)?
    var approvalOpen: (URL, @escaping ()->Bool, @escaping (Bool)->Void)->Bool = {_,_,_ in false}
    var observeAddress: ((WebAudioHandoff.Binding, @escaping (SessionNetworkBinding?) -> Void) -> Bool)?
    // The native assembly keeps its fixed port. Owned test assemblies bind this
    // same value so HTTP/WebSocket authority checks use the actual endpoint.
    var listenerPort: UInt16 = WebNativeListener.defaultPort

    static func native(_ runtime: RuntimeConfiguration, _ session: Session) -> Self {
        // These closures only borrow authorities. No page, credential, timer or socket
        // is constructed until a validated explicit activation reaches the owner.
        .init(observe: { session.observeWebNetworkBinding($0) }, revoke: { session.revokeWebAudio() },
            attach: { session.attachWebAudio($0, completion: $1) }, page: { WebListenerPage.load() },
            credential: { password in
                guard let salt = WebAuthentication.random(16) else { return nil }
                return WebAuthentication.Credential.make(password: password, salt: salt)
            }, listener: { queue, permitted, bound in
                WebNativeListener.native(queue: queue, runtime: runtime, permitted: permitted, bound: bound)
            }, clock: { ProcessInfo.processInfo.systemUptime },
            admissionSchedule: { gate in WebNativeTransport.schedule(permitted: { !runtime.isIsolated && gate() }) },
            peerSchedule: { gate in WebNativeListener.nativeSchedule(permitted: { !runtime.isIsolated && gate() }) },
            scopedAddressQuery: { gate in WebFunnelExecutable.native(isolated:runtime.isIsolated,permitted:gate) },
            addressPermission: { binding in session.permitsWebAddressQuery(binding) },
            approvalOpen: { url,gate,reply in WebFunnelApprovalBrowser.open(url,isolated:runtime.isIsolated,permitted:gate,completion:reply) },
            observeAddress: { binding, reply in session.observeWebAudioBinding(binding, completion: reply) })
    }
}

private final class WebBrowserOwner {
    private static let maximumWaiters = 16, maximumPasswordBytes = 1024
    private let queue: DispatchQueue, isolated: Bool, dependencies: WebBrowserDependencies, lock = NSLock()
    private var room: WebRoom.Service!, handoff: WebAudioHandoff.Service!, lifecycle: WebServiceLifecycle!
    private final class AudioWork {
        let request:UUID,visit:UUID,binding:WebAudioHandoff.Binding?,reply:(Bool)->Void
        var pending=true,cancelled=false,succeeded=false,delivering=false
        init(_ request:UUID,_ visit:UUID,_ binding:WebAudioHandoff.Binding?,_ reply:@escaping(Bool)->Void) {self.request=request;self.visit=visit;self.binding=binding;self.reply=reply}
    }
    private var audioWork:AudioWork?,audioPrepared:UUID?

    // Admission and public value snapshots are locked, including while the owner is
    // blocked in a synchronous credential/page provider. Resource work stays serial.
    private var latest: UUID?, preparation: UUID?, prepared: UUID?, visit: UUID?, pending: UUID?
    private var enabled = false, permanent = false, closing = false, failed = false
    private var waiters = [Waiter](), keepAlive: WebBrowserOwner?
    private var value = BrowserListenerStatus(state: .off, boundPort: nil, sourceAttached: false, retiring: false)
    private var observed: WebAudioHandoff.Binding?, lowerClosed = false, listenerOnly = false
    private struct Activation {
        let visit: UUID, reply: (BrowserListenerActivationResult) -> Void
        var result: BrowserListenerActivationResult?
    }
    // One receipt shares the existing activation credit. The first retirement cause
    // is retained until all lower resources and admitted observation work have closed.
    private var activation: Activation?
    private var addressQuery: WebFunnelQuery.Service!, addressJob: AddressJob?, addressReceipt: BrowserListenerAddress?
    private enum AddressAction {
        case refresh((BrowserListenerAddressResult)->Void)
        case copy(BrowserListenerAddress,(String?)->Void)
        case review((BrowserListenerFunnelReviewResult)->Void)
        case turnOn((BrowserListenerFunnelResult)->Void)
    }
    private final class AddressJob {
        let id=UUID(),visit:UUID,port:UInt16,action:AddressAction
        let binding:WebAudioHandoff.Binding?,listenerOnly:Bool
        var cancelled=false,observing=false,querying=false,opening=false,opened=false,delivering=false,proved=false
        var result:WebFunnelQuery.Result?
        var copy:BrowserListenerAddress? {if case .copy(let token,_)=action {return token};return nil}
        var review:Bool {if case .review=action {return true};return false}
        var turnsOn:Bool {if case .turnOn=action {return true};return false}
        init(_ visit:UUID,_ port:UInt16,_ action:AddressAction,_ binding:WebAudioHandoff.Binding?,_ listenerOnly:Bool) {self.visit=visit;self.port=port;self.action=action;self.binding=binding;self.listenerOnly=listenerOnly}
    }
    private enum Waiter { case prepare(UUID, UUID, (Bool) -> Void), close(() -> Void) }
    private final class Observation {
        private let lock = NSLock(); private var taken = false
        var admitted = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; guard !taken else { return false }; taken = true; return true }
    }
    init(_ queue: DispatchQueue, _ isolated: Bool, _ dependencies: WebBrowserDependencies) {
        self.queue = queue; self.isolated = isolated; self.dependencies = dependencies
    }
    func assemble() {
        addressQuery = WebFunnelQuery.Service(queue: queue, isolated: isolated, enabled: true, current: { [weak self] scope in
            self?.addressPermitted(scope) ?? false
        }, launch: { [weak self] plan,sink in self?.launchAddress(plan,sink) })
        let permission = { [weak self] in self?.allowed ?? false }
        room = WebRoom.Service(queue: queue, isolated: isolated, permitted: permission, listener: { [weak self] gate in
            guard let self, let id = currentVisit, allowed else { return nil }
            return dependencies.listener(queue, gate, { [weak self] port in
                guard let self else { return }; queue.async { [self] in self.bound(port, id) }
            })
        }, clock: dependencies.clock, schedule: { [weak self] queue, pulse in
            guard let self, allowed else { return nil }
            return dependencies.admissionSchedule(permission)(queue, pulse)
        }, peerSchedule: { [weak self] queue, pulse in
            guard let self, allowed else { return nil }
            return dependencies.peerSchedule(permission)(queue, pulse)
        }, retiring: { [weak self] in self?.retiring() })
        handoff = WebAudioHandoff.Service(queue: queue, isolated: isolated, permitted: permission, factory: { [weak self] _, gate in
            guard let self, allowed else { return nil }; return WebAudioHandoff.roomSink(room, permitted: gate)
        })
        lifecycle = WebServiceLifecycle(queue: queue, isolated: isolated, permitted: permission, room: room, handoff: handoff,
            matches: { [weak self] binding in guard let self else { return false }; return allowed && observed == binding },
            revoke: dependencies.revoke, attach: dependencies.attach, activated: { [weak self] binding in self?.attached(binding) })
    }
    var status: BrowserListenerStatus { lock.lock(); defer { lock.unlock() }; return value }
    private var currentVisit: UUID? { lock.lock(); defer { lock.unlock() }; return visit }
    private var allowed: Bool { lock.lock(); defer { lock.unlock() }; return !isolated && enabled && !closing && !permanent && visit != nil }
    private func valid(_ id: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return !isolated && enabled && !closing && !permanent && visit == id }
    func prepare(_ id: UUID, _ completion: @escaping (Bool) -> Void) -> Bool {
        request(false, id, .prepare(id, UUID(), completion), failure: false)
    }
    func close(_ shutdown: Bool, _ completion: (() -> Void)?) -> Bool {
        request(shutdown, nil, completion.map(Waiter.close), failure: false)
    }
    private func request(_ shutdown: Bool, _ request: UUID?, _ waiter: Waiter?, failure: Bool) -> Bool {
        lock.lock()
        guard (request == nil || !permanent), waiter == nil || waiters.count < Self.maximumWaiters else { lock.unlock(); return false }
        if let waiter { waiters.append(waiter) }
        if case .prepare(_, let generation, _)? = waiter { preparation = generation } else { preparation = nil }
        if activation != nil, activation?.result == nil { activation?.result = failure ? .unavailable : .cancelled }
        audioWork?.cancelled=true;audioPrepared=nil
        addressJob?.cancelled = true; addressReceipt = nil
        latest = request; prepared = nil; enabled = false; visit = nil; listenerOnly = false
        permanent = permanent || shutdown; failed = failure
        let first = !closing; closing = true; keepAlive = self
        if first { lowerClosed = false }
        value = .init(state: failure ? .unavailable : (request == nil ? .stopping : .preparing), boundPort: nil, sourceAttached: false, retiring: true)
        lock.unlock()
        addressQuery.cancel()
        dependencies.revoke()
        if shutdown { _ = lifecycle.shutdown() } else { _ = lifecycle.stop() }
        if first { queue.async { [self] in beginClose() } }
        return true
    }
    private func beginClose() {
        let once = Observation()
        let callback = { [self] in
            guard once.claim() else { return }
            queue.async { [self] in lock.lock(); lowerClosed = true; lock.unlock(); finishAddress(); finishAudio(); finishClose() }
        }
        lock.lock(); let terminal = permanent; lock.unlock()
        // One reserved lower waiter, independent of the bounded public waiters.
        if terminal { _ = lifecycle.shutdown(callback) } else { _ = lifecycle.stop(callback) }
    }
    private func finishClose() {
        lock.lock(); guard lowerClosed, closing, pending == nil, addressJob == nil, audioWork == nil else { lock.unlock(); return }
        let callbacks = waiters; waiters.removeAll(); closing = false; observed = nil
        let receipt = activation; activation = nil
        let next = permanent ? nil : latest; prepared = next
        value = .init(state: permanent ? .closed : (failed ? .unavailable : .off), boundPort: nil, sourceAttached: false, retiring: false)
        keepAlive = nil; lock.unlock()
        if let receipt, let result = receipt.result { receipt.reply(result) }
        for callback in callbacks {
            switch callback {
            case .prepare(let id, let generation, let reply):
                lock.lock(); let accepted = !permanent && !closing && preparation == generation && prepared == id && latest == id; lock.unlock(); reply(accepted)
            case .close(let reply): reply()
            }
        }
    }
    func prepareAudio(_ request:UUID,_ reply:@escaping(Bool)->Void)->Bool {
        lock.lock()
        guard !permanent,!closing,pending==nil,audioWork==nil else {lock.unlock();return false}
        guard !isolated,enabled,let visit,value.state == .listening,let port=value.boundPort,port>0 else {
            lock.unlock();return prepare(request,reply)
        }
        let work=AudioWork(request,visit,nil,reply);audioWork=work;audioPrepared=nil;latest=request
        addressJob?.cancelled=true;addressReceipt=nil;observed=nil;listenerOnly=true
        value = .init(state:.listening,boundPort:port,sourceAttached:false,retiring:false);lock.unlock()
        dependencies.revoke();addressQuery.cancel()
        queue.async { [self] in
            guard audioLive(work) else {work.pending=false;finishAudio();return}
            let once=Observation()
            once.admitted=lifecycle.detachAudio { [self] accepted in
                guard once.claim() else {return};queue.async { [self] in
                    guard audioCurrent(work) else {return};work.pending=false;work.succeeded=accepted
                    if !accepted,audioLive(work) {fail()};finishAudio()
                }
            }
            if !once.admitted {work.pending=false;if audioLive(work) {fail()};finishAudio()}
        }
        return true
    }
    func attachAudio(_ request:UUID,_ network:SessionNetworkBinding,_ reply:@escaping(Bool)->Void)->Bool {
        lock.lock()
        guard !isolated,!permanent,!closing,pending==nil,audioWork==nil,audioPrepared==request,latest==request,
              enabled,let visit,value.state == .listening,listenerOnly,network.port>0 else {lock.unlock();return false}
        let binding=WebAudioHandoff.Binding(request:request,network:network),work=AudioWork(request,visit,binding,reply)
        audioWork=work;audioPrepared=nil;addressJob?.cancelled=true;addressReceipt=nil;lock.unlock();addressQuery.cancel()
        queue.async { [self] in
            guard audioLive(work) else {work.pending=false;finishAudio();return}
            let once=Observation()
            once.admitted=dependencies.observe { [self] actual in
                guard once.claim() else {return};queue.async { [self] in
                    guard audioCurrent(work) else {return}
                    guard audioLive(work),actual==network else {work.pending=false;if audioLive(work) {fail()};finishAudio();return}
                    lock.lock();observed=binding;listenerOnly=false;lock.unlock()
                    let receipt=Observation()
                    receipt.admitted=lifecycle.attachAudio(binding) { [self] accepted in
                        guard receipt.claim() else {return};queue.async { [self] in
                            guard audioCurrent(work) else {return};work.pending=false;work.succeeded=accepted
                            if !accepted,audioLive(work) {fail()};finishAudio()
                        }
                    }
                    if !receipt.admitted {work.pending=false;if audioLive(work) {fail()};finishAudio()}
                }
            }
            if !once.admitted {work.pending=false;if audioLive(work) {fail()};finishAudio()}
        }
        return true
    }
    private func audioCurrent(_ work:AudioWork)->Bool {lock.lock();defer{lock.unlock()};return audioWork === work}
    private func audioLive(_ work:AudioWork)->Bool {
        lock.lock();defer{lock.unlock()}
        return audioWork === work && !work.cancelled && !isolated && !permanent && !closing && enabled && visit==work.visit && latest==work.request
    }
    private func finishAudio() {
        lock.lock()
        guard let work=audioWork,!work.pending,!work.delivering,addressJob==nil,!closing || lowerClosed else {lock.unlock();return}
        let accepted = !work.cancelled && work.succeeded && !permanent && !closing && enabled && visit==work.visit && latest==work.request
        if accepted,work.binding==nil {audioPrepared=work.request}
        work.delivering=true;lock.unlock();work.reply(accepted)
        lock.lock();if audioWork === work {audioWork=nil};lock.unlock();finishClose()
    }
    func activate(_ request: UUID, _ binding: SessionNetworkBinding?, _ options: BrowserListenerOptions, _ password: String, _ completion: ((BrowserListenerActivationResult) -> Void)? = nil) -> Bool {
        lock.lock()
        guard !isolated, !permanent, !closing, pending == nil, audioWork == nil, prepared == request, latest == request,
              options.enabled, binding.map({ $0.port > 0 }) ?? true, dependencies.listenerPort > 0 else { lock.unlock(); return false }
        let bytes = Array(password.utf8.prefix(Self.maximumPasswordBytes + 1))
        guard !bytes.isEmpty, bytes.count <= Self.maximumPasswordBytes else { lock.unlock(); return false }
        let borrowed = String(decoding: bytes, as: UTF8.self), id = UUID()
        prepared = nil; pending = id; visit = id; enabled = true; listenerOnly = binding == nil
        activation = completion.map { Activation(visit: id, reply: $0) }
        value = .init(state: .starting, boundPort: nil, sourceAttached: false, retiring: false); lock.unlock()
        let source=binding.map { WebAudioHandoff.Binding(request:request,network:$0) }
        queue.async { [self] in observe(id, source, options, borrowed) }; return true
    }
    private func observe(_ id: UUID, _ binding: WebAudioHandoff.Binding?, _ options: BrowserListenerOptions, _ password: String) {
        guard valid(id) else { finishedObservation(id); return }
        let receipt = Observation()
        receipt.admitted = dependencies.observe { [self] actual in
            guard receipt.claim() else { return }
            queue.async { [self] in
                guard receipt.admitted else { return }
                defer { finishedObservation(id) }
                guard valid(id) else { return }
                guard actual == binding?.network else { fail(); return }
                lock.lock(); observed = binding; lock.unlock()
                let configuration: () -> WebRoom.Configuration? = { [self] in
                    guard self.valid(id), let page = self.dependencies.page(), self.valid(id),
                          let credential = self.dependencies.credential(password), self.valid(id) else { return nil }
                    let port = self.dependencies.listenerPort
                    var policy = WebAdmission.Policy(hosts: ["127.0.0.1:\(port)", "localhost:\(port)"], origins: ["http://127.0.0.1:\(port)", "http://localhost:\(port)"])
                    policy.autoStart = options.autoStart
                    return .init(credential: credential, page: page, policy: policy, source: "RemSound Mac")
                }
                let started:Bool
                if let binding { started=lifecycle.start(binding,configuration:configuration) }
                else { started=lifecycle.startStopped(configuration:configuration) }
                if !started, valid(id) { fail() }
            }
        }
        if !receipt.admitted { if valid(id) { fail() }; finishedObservation(id) }
    }
    private func finishedObservation(_ id: UUID) {
        lock.lock(); if pending == id { pending = nil }; lock.unlock(); completeActivation(id); finishClose()
    }
    private func bound(_ port: UInt16, _ id: UUID) {
        guard port > 0, valid(id) else { return }
        lock.lock(); guard visit == id, enabled, !closing, !permanent else { lock.unlock(); return }
        value = .init(state: value.sourceAttached || listenerOnly ? .listening : .starting, boundPort: port, sourceAttached: value.sourceAttached, retiring: false); lock.unlock(); completeActivation(id)
    }
    private func attached(_ binding: WebAudioHandoff.Binding) {
        guard allowed, observed == binding else { return }
        lock.lock(); guard enabled, !closing, !permanent else { lock.unlock(); return }
        value = .init(state: value.boundPort == nil ? .starting : .listening, boundPort: value.boundPort, sourceAttached: true, retiring: false); let id = visit; lock.unlock()
        if let id { completeActivation(id) }
    }
    private func completeActivation(_ id: UUID) {
        lock.lock()
        guard let receipt = activation, receipt.visit == id, visit == id, pending == nil,
              enabled, !closing, !permanent, value.state == .listening, let port = value.boundPort else { lock.unlock(); return }
        activation = nil; lock.unlock()
        // Claim under the admission lock. A subsequent Stop cannot revoke this
        // historical local receipt; it still fences and retires the actual service.
        receipt.reply(.listening(port: port))
    }
    func refreshAddress(_ completion:@escaping(BrowserListenerAddressResult)->Void)->Bool {admitAddress(.refresh(completion))}
    func copyAddress(_ value:BrowserListenerAddress,_ completion:@escaping(String?)->Void)->Bool {admitAddress(.copy(value,completion))}
    func reviewPublicAccess(_ completion:@escaping(BrowserListenerFunnelReviewResult)->Void)->Bool {admitAddress(.review(completion))}
    func turnOnPublicAccess(_ completion:@escaping(BrowserListenerFunnelResult)->Void)->Bool {admitAddress(.turnOn(completion))}
    private func admitAddress(_ action:AddressAction)->Bool {
        lock.lock()
        guard !isolated,enabled,!closing,!permanent,pending==nil,addressJob==nil,audioWork==nil,
              let visit,value.state == .listening,(value.sourceAttached || listenerOnly),let port=value.boundPort,port>0 else {lock.unlock();return false}
        if case .copy(let token,_)=action {
            guard token.publiclyAllowed,token==addressReceipt,token.visit==visit,token.port==port else {lock.unlock();return false}
        }
        let job=AddressJob(visit,port,action,observed,listenerOnly);addressJob=job
        if job.copy==nil {addressReceipt=nil}
        lock.unlock();queue.async{[self] in observeAddress(job,afterQuery:false)};return true
    }
    func cancelAddress() {
        lock.lock();let job=addressJob;job?.cancelled=true;addressReceipt=nil;lock.unlock()
        // An idle revocation must not cancel work admitted afterwards. Match the
        // captured query visit and finish only that job, never a later replacement.
        guard let job else {return}
        addressQuery.cancel(.init(identity:job.id,localPort:job.port))
        queue.async{[self] in finishAddress(job)}
    }
    private func addressPermitted(_ scope: WebFunnelQuery.Scope) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let job = addressJob else { return false }
        return addressLiveLocked(job) && job.id == scope.identity && job.port == scope.localPort
    }
    private func launchAddress(_ plan:WebFunnelQuery.Plan,_ sink:WebFunnelQuery.Sink)->WebFunnelQuery.Child? {
        lock.lock()
        guard let job=addressJob,addressLiveLocked(job),job.proved else {lock.unlock();return nil}
        lock.unlock()
        guard let provider=dependencies.scopedAddressQuery else {return dependencies.addressQuery(plan,sink)}
        // A listener-only visit owns no audio binding. Running visits still
        // recheck the actual installed source, not Session's cached health.
        let gate={ [weak self,weak job] in
            guard let self,let job,self.addressLive(job),sink.isPermitted,
                  self.addressExecutionPermitted(job) else {return false}
            return self.addressLive(job) && sink.isPermitted
        }
        guard gate() else {return nil}
        return provider(gate)(plan,sink)
    }
    private func addressExecutionPermitted(_ job:AddressJob)->Bool {
        guard addressLive(job) else {return false}
        if let binding=job.binding {
            guard !job.listenerOnly,dependencies.addressPermission?(binding)==true else {return false}
        } else if !job.listenerOnly {return false}
        return addressLive(job)
    }
    private func addressLiveLocked(_ job: AddressJob) -> Bool {
        !isolated && enabled && !closing && !permanent && addressJob === job && !job.cancelled && visit == job.visit &&
            value.state == .listening && (value.sourceAttached || listenerOnly) && value.boundPort == job.port
            && listenerOnly == job.listenerOnly && observed == job.binding
    }
    private func addressLive(_ job: AddressJob) -> Bool { lock.lock(); defer { lock.unlock() }; return addressLiveLocked(job) }
    private func observeAddress(_ job: AddressJob, afterQuery: Bool) {
        guard addressLive(job) else { finishAddress(job); return }
        job.proved = false
        let receipt = Observation(); job.observing = true
        let received:(SessionNetworkBinding?)->Void = { [self] actual in
            guard receipt.claim() else { return }
            queue.async { [self] in
                guard receipt.admitted else { return }
                job.observing = false
                guard addressLive(job) else { finishAddress(job); return }
                guard actual == job.binding?.network else {
                    fail(); finishAddress(job); return
                }
                job.proved = true
                if job.copy != nil || afterQuery { finishAddress(job) }
                else { startAddressQuery(job) }
            }
        }
        if let expected=job.binding,let observe=dependencies.observeAddress {
            receipt.admitted=observe(expected,received)
        } else if job.listenerOnly,job.binding==nil {
            receipt.admitted=dependencies.observe(received)
        } else {
            job.observing=false;job.result = .failed(.unavailable);finishAddress(job);return
        }
        if !receipt.admitted { job.observing = false; fail(); finishAddress(job) }
    }
    private func startAddressQuery(_ job: AddressJob) {
        guard addressLive(job) else { finishAddress(job); return }
        job.querying = true
        let completion: (WebFunnelQuery.Result) -> Void = { [self] result in
            // The query owner retains its own credit through its raw result return.
            queue.async { [self] in
                job.querying = false; job.result = result
                if job.turnsOn,case .failed(.notInstalled)=result,self.addressLive(job) {
                    job.opening=true;let receipt=Observation()
                    receipt.admitted=self.openPrintedPage(WebFunnelStatus.downloadPage,job:job) { [self] success in
                        guard receipt.claim() else {return}
                        queue.async {guard receipt.admitted else {return};job.opening=false;job.opened=success;self.finishAddress(job)}
                    }
                    if !receipt.admitted {job.opening=false;self.finishAddress(job)}
                    return
                }
                if addressLive(job) { observeAddress(job, afterQuery: true) } else { finishAddress(job) }
            }
        }
        let scope = WebFunnelQuery.Scope(identity: job.id, localPort: job.port)
        let admitted:Bool
        if job.turnsOn {admitted=addressQuery.turnOn(scope,openPage:{[self] url,done in openPrintedPage(url,job:job){_ in done()}},completion:completion)}
        else if job.review {admitted=addressQuery.prepareEnable(scope,completion:completion)}
        else {admitted=addressQuery.request(scope,completion:completion)}
        if !admitted { job.querying = false; job.result = .failed(.unavailable); finishAddress(job) }
    }
    private func openPrintedPage(_ url:URL,job:AddressJob,completion:@escaping(Bool)->Void)->Bool {
        guard addressExecutionPermitted(job) else {return false}
        let gate={ [weak self,weak job] in
            guard let self,let job,self.addressExecutionPermitted(job) else {return false}
            return self.addressLive(job)
        }
        return dependencies.approvalOpen(url,gate,completion)
    }
    private func finishAddress(_ expected: AddressJob? = nil) {
        lock.lock()
        guard let job = addressJob, expected == nil || job === expected, !job.observing, !job.querying, !job.opening, !job.delivering, !closing || lowerClosed else { lock.unlock(); return }
        let live = addressLiveLocked(job)
        let result: BrowserListenerAddressResult
        var copied: String?
        if !live { result = .cancelled }
        else if let token = job.copy {
            result = .unknown
            if job.proved, token == addressReceipt { copied = token.urlString }
        } else {
            switch job.result {
            case .mapping(let address, let allowed):
                let token = BrowserListenerAddress(urlString: address.url.absoluteString, publiclyAllowed: allowed, visit: job.visit, receipt: UUID(), port: job.port)
                addressReceipt = token; result = .configured(token)
            case .failed(.notInstalled): result = .notInstalled
            case .failed(.unavailable): result = .unavailable
            case .failed(.cancelled): result = .cancelled
            default: result = .unknown
            }
        }
        let review: BrowserListenerFunnelReviewResult
        if !live { review = .cancelled }
        else {
            switch job.result {
            case .enablePreflight(.ready(let observation)) where job.proved && observation.source == job.id && observation.localPort == job.port:
                review = observation.wasEmpty ? .empty : .matching(publiclyAllowed: observation.alreadyAllowed)
            case .enablePreflight(.conflict): review = .conflict
            case .failed(.unavailable): review = .unavailable
            case .failed(.cancelled): review = .cancelled
            default: review = .unknown
            }
        }
        let turnedOn:BrowserListenerFunnelResult
        if !live {turnedOn = .cancelled}
        else if job.opened {turnedOn = .downloadOpened}
        else {switch job.result {case .turnedOn:turnedOn = .enabled;case .failed(.cancelled):turnedOn = .cancelled;default:turnedOn = .unavailable}}
        job.delivering = true; lock.unlock()
        switch job.action {
        case .refresh(let reply):reply(result)
        case .copy(_,let reply):reply(copied)
        case .review(let reply):reply(review)
        case .turnOn(let reply):reply(turnedOn)
        }
        lock.lock(); if addressJob === job { addressJob = nil }; lock.unlock()
        finishAudio();finishClose()
    }
    func describeBrowsers(_ reply: @escaping ([String]) -> Void) {
        queue.async { [weak self] in
            let lines = (self?.room?.browsers ?? []).map { entry -> String in
                let s = entry.snapshot
                let report = s.report.map { r in
                    WebBrowsersText.report(streams: r.streams.map { .init(id: $0.id, depthMs: $0.depthMs, targetMs: $0.targetMs,
                        longestWaitMs: $0.longestWaitMs, gaps: $0.gaps, skips: $0.skips) }, outMs: r.outMs, rate: r.rate)
                }
                return WebBrowsersText.line(number: entry.number, description: WebBrowsersText.describe(pcm: s.pcm, report: report,
                    roundTrips: s.roundTrips, dropped: s.droppedAudio, reconnects: s.report?.reconnects ?? 0))
            }
            DispatchQueue.main.async { reply(lines) }
        }
    }
    #if DEBUG
    func testPeerReports() -> [WebPeer.Report] {
        queue.sync { room.peers?.compactMap(\.report) ?? [] }
    }
    #endif
    private func retiring() { if allowed { fail() } }
    private func fail() { _ = request(false, nil, nil, failure: true) }
}
