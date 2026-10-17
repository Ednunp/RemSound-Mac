import Foundation

enum CaptureCleanupPolicy {
    static let maximumPolls = 1000
    static let pollInterval: DispatchTimeInterval = .milliseconds(10)
}

// Shared across one Session's DeviceAudio generations on its serial worker.
// Failed native registrations block replacement capture and retain immutable
// callback contexts until both unregister and entered-callback barriers finish.
final class CaptureRetirements {
    private var pending = [DirectInputRegistration]()
    private var lastDestroyStatus = [ObjectIdentifier: Int32]()
    var noteFailure: (String) -> Void = { _ in }
    private func note(_ registration: DirectInputRegistration, initial: Bool) {
        if initial, let status = registration.stopStatus, status != 0 {
            noteFailure("Direct input stop returned Core Audio error \(status); checking unregister and callback retirement.")
        }
        let id = ObjectIdentifier(registration)
        if let status = registration.destroyStatus, status != 0,
            lastDestroyStatus[id] != status {
            lastDestroyStatus[id] = status
            noteFailure("Direct input unregister returned Core Audio error \(status); retaining callback ownership.")
        }
    }
    var count: Int { pending.count }
    var exhausted: Bool { pending.contains { $0.retirementExhausted } }
    @discardableResult
    func retire(_ registration: DirectInputRegistration,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        let known = pending.contains { $0 === registration }
        let complete = registration.retire(now: now)
        note(registration, initial: !known)
        if complete { lastDestroyStatus.removeValue(forKey: ObjectIdentifier(registration)); return true }
        if !known { pending.append(registration) }
        return false
    }
    @discardableResult
    func poll(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        pending.removeAll { registration in
            let complete = registration.pollRetirement(now: now)
            note(registration, initial: false)
            if complete { lastDestroyStatus.removeValue(forKey: ObjectIdentifier(registration)) }
            return complete
        }
        return pending.isEmpty
    }
}

// Final Session release may occur on any thread. This resource-only owner drains
// capture on its original worker without keeping an active Session alive.
final class CaptureResourceCleanup {
    private let owner: DispatchQueue
    private var audio: DeviceAudio?
    private let retirements: CaptureRetirements
    private var wakes: [CaptureWakeAttachment]
    private var remainingPolls: Int
    private var timer: DispatchSourceTimer?
    private var retention: CaptureResourceCleanup?

    init(owner: DispatchQueue, audio: DeviceAudio?, retirements: CaptureRetirements,
        wakes: [CaptureWakeAttachment], remainingPolls: Int) {
        self.owner = owner
        self.audio = audio
        self.retirements = retirements
        self.wakes = wakes
        self.remainingPolls = remainingPolls
    }
    func start() {
        dispatchPrecondition(condition: .onQueue(owner))
        retention = self
        audio?.stop()
        audio = nil
        let stopped = retirements.poll()
        for wake in wakes { wake.retire(producersStopped: stopped) }
        poll()
        guard retention != nil, remainingPolls > 0, !retirements.exhausted else { return }
        let timer = DispatchSource.makeTimerSource(queue: owner)
        self.timer = timer
        timer.schedule(deadline: .now() + CaptureCleanupPolicy.pollInterval,
            repeating: CaptureCleanupPolicy.pollInterval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            remainingPolls -= 1
            poll()
            if remainingPolls == 0 || retirements.exhausted {
                self.timer?.cancel()
                self.timer = nil
                // Keep uncertain callback/consumer memory, with no retry loop.
            }
        }
        timer.resume()
    }
    private func poll() {
        let stopped = retirements.poll()
        for wake in wakes { _ = wake.poll(producersStopped: stopped) }
        wakes.removeAll { $0.disposed }
        guard stopped, wakes.isEmpty else { return }
        timer?.cancel()
        timer = nil
        retention = nil
    }
}
