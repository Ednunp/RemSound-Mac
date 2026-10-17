import Foundation

// One persistent room preserves failure history. This owner joins source, Room and
// Session attachment retirement; the App facade and native assembly remain separate.
final class WebServiceLifecycle {
    enum State: Equatable { case off, starting, running, stopping, closed }
    // Lifecycle receipt stage, not listener health or remote delivery.
    struct Snapshot { let state: State, binding: WebAudioHandoff.Binding? }
    init(queue: DispatchQueue, isolated: Bool = true, permitted: @escaping () -> Bool = { false },
         room: WebRoom.Service, handoff: WebAudioHandoff.Service,
         matches: @escaping (WebAudioHandoff.Binding) -> Bool,
         revoke: @escaping () -> Void,
         attach: @escaping (WebAudioHandoff.Producer, @escaping (Bool) -> Void) -> Bool,
         activated: @escaping (WebAudioHandoff.Binding) -> Void = { _ in }) {
        owner = Owner(queue, isolated, permitted, room, handoff, matches, revoke, attach, activated)
    }
    // Both lower services must be exclusive to this lifecycle on the same serial queue.
    // revoke is a thread-safe admission fence; matches and attach run on that owner.
    private let owner: Owner
    // Owner-only admission, not a Session worker acceptance or network delivery receipt.
    func start(_ binding: WebAudioHandoff.Binding, configuration: () -> WebRoom.Configuration?) -> Bool { owner.start(binding, configuration) }
    func startStopped(configuration: () -> WebRoom.Configuration?) -> Bool { owner.start(nil, configuration) }
    func detachAudio(completion: @escaping (Bool) -> Void) -> Bool { owner.detachAudio(completion) }
    func attachAudio(_ binding: WebAudioHandoff.Binding, completion: @escaping (Bool) -> Void) -> Bool { owner.attachAudio(binding, completion) }
    func stop(_ completion: (() -> Void)? = nil) -> Bool { owner.request(false, completion) }
    func shutdown(_ completion: (() -> Void)? = nil) -> Bool { owner.request(true, completion) }
    var snapshot: Snapshot? { owner.snapshot }
    deinit { _ = owner.request(true, nil) }

    private final class Once {
        private let lock = NSLock(); private var taken = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; guard !taken else { return false }; taken = true; return true }
    }
    private final class Cycle {
        var binding: WebAudioHandoff.Binding?
        var listenerOnly: Bool
        var running = false, closeStarted = false, sourceClosed = false, roomClosed = false
        var sourcePending = false, attachPending = false, attachAdmitted = false
        var detaching = false, detached = false
        var audioReply: ((Bool) -> Void)?
        init(_ binding: WebAudioHandoff.Binding?, listenerOnly: Bool = false) { self.binding = binding; self.listenerOnly = listenerOnly }
    }
    private final class Owner {
        private static let maximumWaiters = 16
        private let queue: DispatchQueue, key = DispatchSpecificKey<UInt8>(), lock = NSLock(), isolated: Bool
        private let allowed: () -> Bool, matches: (WebAudioHandoff.Binding) -> Bool, revoke: () -> Void
        private let attach: (WebAudioHandoff.Producer, @escaping (Bool) -> Void) -> Bool
        private let room: WebRoom.Service, handoff: WebAudioHandoff.Service
        private let activated: (WebAudioHandoff.Binding) -> Void
        // Admission, waiter reservations and self-retention use lock. Resource receipts
        // and Cycle's mutable fields belong exclusively to the serial owner.
        private var cycle: Cycle?, closing = false, permanent = false, keepAlive: Owner?
        private var waiters = [() -> Void](), reserved = 0
        init(_ queue: DispatchQueue, _ isolated: Bool, _ allowed: @escaping () -> Bool,
             _ room: WebRoom.Service, _ handoff: WebAudioHandoff.Service,
             _ matches: @escaping (WebAudioHandoff.Binding) -> Bool, _ revoke: @escaping () -> Void,
             _ attach: @escaping (WebAudioHandoff.Producer, @escaping (Bool) -> Void) -> Bool,
             _ activated: @escaping (WebAudioHandoff.Binding) -> Void) {
            self.queue = queue; self.isolated = isolated; self.allowed = allowed; self.room = room; self.handoff = handoff
            self.matches = matches; self.revoke = revoke; self.attach = attach; self.activated = activated; queue.setSpecific(key: key, value: 1)
        }
        deinit { queue.setSpecific(key: key, value: nil) }
        private var onOwner: Bool { DispatchQueue.getSpecific(key: key) == 1 }
        private func current(_ value: Cycle) -> Bool { lock.lock(); defer { lock.unlock() }; return cycle === value }
        private func admitted(_ value: Cycle) -> Bool { lock.lock(); defer { lock.unlock() }; return cycle === value && !closing && !permanent }
        private func gate(_ value: Cycle) -> Bool {
            guard onOwner, !isolated, admitted(value), allowed(), admitted(value) else { return false }
            if value.detaching { return false }
            if let binding=value.binding { return matches(binding) && admitted(value) }
            return value.listenerOnly && admitted(value)
        }
        var snapshot: Snapshot? {
            guard onOwner else { return nil }
            lock.lock(); let value = cycle, stopping = closing, terminal = permanent; lock.unlock()
            let state: State = value == nil ? (terminal ? .closed : .off) : (stopping ? .stopping : (value?.running == true ? .running : .starting))
            return Snapshot(state: state, binding: value?.binding)
        }
        func start(_ binding: WebAudioHandoff.Binding?, _ configuration: () -> WebRoom.Configuration?) -> Bool {
            guard onOwner, !isolated, allowed() else { return false }
            if let binding { guard binding.network.port > 0, matches(binding) else { return false } }
            lock.lock(); guard cycle == nil, !closing, !permanent else { lock.unlock(); return false }
            let value = Cycle(binding,listenerOnly:binding == nil); cycle = value; keepAlive = self; lock.unlock()
            guard gate(value), room.start(configuration: { gate(value) ? configuration() : nil }), gate(value) else {
                _ = request(false, nil); return false
            }
            guard let binding else { value.running = true; return true }
            value.sourcePending = true
            let once = Once()
            let accepted = handoff.open(binding) { [self] producer in
                guard once.claim() else { return }; queue.async { [self] in received(producer, value) }
            }
            if !accepted { value.sourcePending = false; _ = request(false, nil); return false }
            return true
        }
        func detachAudio(_ completion: @escaping (Bool) -> Void) -> Bool {
            guard onOwner,!isolated,let value=cycle,admitted(value),allowed(),!value.detaching,value.audioReply==nil,admitted(value) else {return false}
            value.detaching=true;value.detached=false;value.audioReply=completion
            revoke();_ = handoff.stop()
            let once=Once()
            // Source retirement is deliberately independent of the retained Room.
            _ = handoff.stop { [self] in
                guard once.claim() else {return};queue.async { [self] in
                    guard current(value) else {return};value.detached=true;finishDetach(value)
                }
            }
            return true
        }
        private func finishDetach(_ value: Cycle) {
            guard current(value),value.detaching,value.detached,!value.sourcePending,!value.attachPending else {return}
            value.binding=nil;value.listenerOnly=true;value.running=true;value.detaching=false
            let reply=value.audioReply;value.audioReply=nil
            reply?(admitted(value) && allowed());finish(value)
        }
        func attachAudio(_ binding: WebAudioHandoff.Binding,_ completion: @escaping (Bool) -> Void) -> Bool {
            guard onOwner,!isolated,let value=cycle,admitted(value),allowed(),value.binding==nil,
                  !value.detaching,!value.sourcePending,!value.attachPending,value.audioReply==nil,
                  binding.network.port>0,matches(binding),admitted(value) else {return false}
            value.binding=binding;value.listenerOnly=false;value.running=false;value.audioReply=completion;value.sourcePending=true
            let once=Once()
            let accepted=handoff.open(binding) { [self] producer in
                guard once.claim() else {return};queue.async { [self] in received(producer,value) }
            }
            if !accepted {value.sourcePending=false;_ = request(false,nil)}
            return true
        }
        private func received(_ producer: WebAudioHandoff.Producer?, _ value: Cycle) {
            guard current(value) else { _ = producer?.retire(); return }
            value.sourcePending = false
            if value.detaching { _ = producer?.retire();finishDetach(value);finish(value);return }
            guard gate(value), let producer, producer.isActive else {
                _ = producer?.retire(); _ = request(false, nil); finish(value); return
            }
            value.attachPending = true
            let once = Once()
            let accepted = attach(producer) { [self] applied in
                guard once.claim() else { return }
                // Inspect inline or foreign callbacks only after the raw attach method returns.
                queue.async { [self] in attached(applied, producer, value) }
            }
            value.attachAdmitted = accepted
            if !accepted { value.attachPending = false; _ = producer.retire(); _ = request(false, nil) }
        }
        private func attached(_ applied: Bool, _ producer: WebAudioHandoff.Producer, _ value: Cycle) {
            guard current(value), value.attachAdmitted else { return }
            value.attachPending = false
            if value.detaching { _ = producer.retire();finishDetach(value);finish(value);return }
            guard applied, gate(value), producer.isActive else {
                _ = producer.retire(); _ = request(false, nil); finish(value); return
            }
            value.running = true
            if let binding = value.binding { activated(binding) }
            let reply=value.audioReply;value.audioReply=nil;reply?(true)
        }
        // False reserves no completion. Timeouts cannot substitute for missing receipts.
        func request(_ shutdown: Bool, _ completion: (() -> Void)?) -> Bool {
            lock.lock()
            if let completion {
                guard reserved < Self.maximumWaiters else { lock.unlock(); return false }
                reserved += 1; waiters.append(completion)
            }
            let newShutdown = shutdown && !permanent
            if shutdown { permanent = true }
            let first = !closing; closing = true
            if cycle == nil { cycle = Cycle(nil); keepAlive = self }
            let value = cycle!; lock.unlock()
            if first || newShutdown {
                revoke()
                // Lower admission gates close synchronously; their queued cleanup still
                // needs the two independent receipts collected on the owner below.
                if shutdown { _ = handoff.shutdown(); _ = room.shutdown() }
                else { _ = handoff.stop(); _ = room.stop() }
            }
            if first { queue.async { [self] in beginClose(value) } }
            return true
        }
        private func beginClose(_ value: Cycle) {
            lock.lock(); let terminal = permanent; lock.unlock()
            guard current(value), !value.closeStarted else { return }; value.closeStarted = true
            let sourceOnce = Once(), roomOnce = Once()
            let sourceReceipt = { [self] in
                guard sourceOnce.claim() else { return }; queue.async { [self] in guard current(value) else { return }; value.sourceClosed = true; finish(value) }
            }
            let roomReceipt = { [self] in
                guard roomOnce.claim() else { return }; queue.async { [self] in guard current(value) else { return }; value.roomClosed = true; finish(value) }
            }
            // These exclusively owned lower services each reserve one waiter. A refusal
            // deliberately leaves this barrier pending instead of fabricating retirement.
            if terminal { _ = handoff.shutdown(sourceReceipt); _ = room.shutdown(roomReceipt) }
            else { _ = handoff.stop(sourceReceipt); _ = room.stop(roomReceipt) }
            finish(value)
        }
        private func finish(_ value: Cycle) {
            guard current(value), value.closeStarted, value.sourceClosed, value.roomClosed,
                  !value.sourcePending, !value.attachPending else { return }
            lock.lock(); guard cycle === value else { lock.unlock(); return }
            cycle = nil; closing = false; let callbacks = waiters; waiters.removeAll(); keepAlive = nil; lock.unlock()
            let audioReply=value.audioReply;value.audioReply=nil;audioReply?(false)
            for callback in callbacks { lock.lock(); reserved -= 1; lock.unlock(); callback() }
        }
    }
}
