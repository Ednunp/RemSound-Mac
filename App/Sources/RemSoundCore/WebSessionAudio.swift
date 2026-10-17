import Foundation
import RemSoundJam

// Worker-side registration only. Handoff and Room retain their separate cleanup receipts.
final class WebSessionAudio {
    // A bridge instance visit is independent, even when another instance has the same host PID.
    struct PluginKey: Hashable {
        let instance: UInt32, port: UInt16, visit: UUID
        init?(instance: UInt32, endpoint: Endpoint, visit: UUID) {
            guard endpoint.address == "127.0.0.1", endpoint.port > 0 else { return nil }
            self.instance = instance; port = endpoint.port; self.visit = visit
        }
    }
    private final class Active {
        typealias Mixer = PluginSourceMixer<PluginKey>
        let producer: WebAudioHandoff.Producer, mixer: Mixer
        var visits: [PluginKey: Mixer.Clock.Visit] = [:]
        init(_ producer: WebAudioHandoff.Producer) {
            self.producer = producer; mixer = Mixer(generation: producer.binding.request)
            visits.reserveCapacity(Mixer.Clock.maximumSources)
        }
        deinit { _ = mixer.stop(generation: producer.binding.request) }
        func apply(_ state: Mixer.Clock.Receipt?) {
            guard let state else { return }
            for visit in state.retired where visits[visit.key] == visit { visits.removeValue(forKey: visit.key) }
            if let visit = state.visit { visits[visit.key] = visit }
        }
    }
    // Session worker only. The producer is re-proved after mixing, so main-thread revoke
    // fences an in-progress block without touching the worker's mutable mixer.
    func plugin(_ samples: [Float], from source: PluginKey, now: Double) -> Bool {
        guard onOwner else { return false }
        lock.lock(); let visit = active; lock.unlock()
        guard let visit, visit.producer.isActive else { return false }
        let result = visit.mixer.offer(samples, from: source, generation: visit.producer.binding.request, now: now)
        visit.apply(result.state)
        if visit.mixer.isClosed { _ = visit.producer.retire(); return false }
        guard result.failure == nil, visit.producer.isActive else { return false }
        if let output = result.samples { return visit.producer.offer(output, lane: .mixed) }
        return result.state?.role == .secondary
    }
    func retirePlugin(_ source: PluginKey) {
        guard onOwner else { return }
        lock.lock(); let visit = active; lock.unlock()
        guard let visit, let ticket = visit.visits[source] else { return }
        visit.apply(visit.mixer.retire(ticket))
    }

    private struct Pending {
        let producer: WebAudioHandoff.Producer
        let completion: (Bool) -> Void
    }
    private let queue: DispatchQueue, key = DispatchSpecificKey<UInt8>(), lock = NSLock()
    private var pending: Pending?, active: Active?, scheduled = false
    init(queue: DispatchQueue) { self.queue = queue; queue.setSpecific(key: key, value: 1) }
    deinit { revoke(); queue.setSpecific(key: key, value: nil) }
    private var onOwner: Bool { DispatchQueue.getSpecific(key: key) == 1 }

    // True transfers one registration, not sample/network authority. False leaves it with the caller.
    func request(_ producer: WebAudioHandoff.Producer, completion: @escaping (Bool) -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !scheduled, active == nil, producer.isActive else { return false }
        pending = Pending(producer: producer, completion: completion); scheduled = true
        return true
    }
    func apply(running: Bool, binding: SessionNetworkBinding?) {
        guard onOwner else { return }
        lock.lock()
        let next = pending; pending = nil; scheduled = false
        let accepted = next.map { running && (binding.map { $0.port > 0 } ?? false)
            && binding == $0.producer.binding.network && $0.producer.isActive } ?? false
        if accepted, let next { active = Active(next.producer) }
        lock.unlock()
        if !accepted { _ = next?.producer.retire() }
        next?.completion(accepted)
    }
    // Revocation is immediate even while Session's worker has earlier work queued.
    // Keep scheduled reserved until that work returns, so repeated requests cannot grow its queue.
    func revoke() {
        lock.lock(); let waiting = pending, previous = active; pending = nil; active = nil; lock.unlock()
        _ = waiting?.producer.retire(); _ = previous?.producer.retire(); waiting?.completion(false)
    }
    // A locked current-producer receipt only; worker observation still proves the
    // running socket before/after a query. This does not report ongoing health.
    func permitsAddressQuery(_ binding:WebAudioHandoff.Binding)->Bool {
        lock.lock();defer{lock.unlock()}
        return active?.producer.binding==binding && active?.producer.isActive==true
    }
    func matches(_ binding: WebAudioHandoff.Binding) -> Bool {
        guard onOwner else { return false }
        return permitsAddressQuery(binding)
    }
    var hasDestination: Bool {
        guard onOwner else { return false }
        lock.lock(); defer { lock.unlock() }; return active?.producer.isActive ?? false
    }
    func capture(_ samples: [Float], lane: PushToTalkSendLane) -> Bool {
        guard onOwner else { return false }
        let route: WebAudio.Lane
        switch lane {
        case .inputCapture: route = .wasapi
        case .systemCapture: route = .asio
        // Independent plugin clocks require a summed producer, not concatenated instance blocks.
        case .plugin: return false
        }
        lock.lock(); let producer = active?.producer; lock.unlock()
        return producer?.offer(samples, lane: route) ?? false
    }
}
