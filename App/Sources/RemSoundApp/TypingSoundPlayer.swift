import Foundation
import AudioSupport
import RemSoundRuntime

protocol TypingSoundOutput: AnyObject {
    var isRunning: Bool { get }
    func start() throws
    func setEnabled(_ enabled: Bool)
    func enqueue(key: Int, password: Bool)
    func stop()
}

struct TypingAudioCache {
    var assets: [Int: [Float]]
    var keys: [Int] { assets.keys.filter { (0..<Int(RS_TYPING_PASSWORD_ASSET)).contains($0) }.sorted() }
}

final class TypingSoundPlayer {
    // Lifecycle/policy calls belong to the GUI thread; queued work is the serial producer.
    private static let retryInterval: TimeInterval = 5
    private let configuration: RuntimeConfiguration
    private let preferences: CuePreferences
    // The enqueue boundary must be serial: it is the native mixer's single producer.
    private let enqueue: (@escaping () -> Void) -> Void
    private let load: () -> TypingAudioCache
    private let makeOutput: (TypingAudioCache) throws -> TypingSoundOutput
    private let clock: () -> TimeInterval
    private let choose: (Int) -> Int
    private let flush: () -> Void
    private let policyLock = NSLock()
    private var started = false
    private var allowed = false
    private var generation: UInt64 = 0
    private var output: TypingSoundOutput?
    // Decoding, construction and retry state belong exclusively to the producer queue.
    private var cache: TypingAudioCache?
    private var retryAt: TimeInterval?
    init(configuration: RuntimeConfiguration, preferences: CuePreferences,
         enqueue: @escaping (@escaping () -> Void) -> Void,
         load: @escaping () -> TypingAudioCache,
         makeOutput: @escaping (TypingAudioCache) throws -> TypingSoundOutput,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         choose: @escaping (Int) -> Int = { Int.random(in: 0..<$0) },
         flush: @escaping () -> Void = {}) {
        self.configuration = configuration; self.preferences = preferences
        self.enqueue = enqueue; self.load = load; self.makeOutput = makeOutput
        self.clock = clock; self.choose = choose
        self.flush = flush
    }
    deinit { stop() }
    func start() { started = true; refresh() }
    func refresh() {
        let next = started && !configuration.silent && !configuration.isHeadless &&
            preferences.automaticKeyboardClicksEnabled
        policyLock.lock()
        guard next != allowed else { policyLock.unlock(); return }
        generation &+= 1; allowed = next
        let current = generation
        let retired = next ? nil : output
        if !next {
            // Only this atomic native gate runs under the policy lock, never device teardown.
            retired?.setEnabled(false); output = nil
        }
        policyLock.unlock()
        if next { enqueue { [weak self] in self?.perform(password: nil, generation: current) } }
        else { enqueue { [weak self] in retired?.stop(); self?.retryAt = nil } }
    }
    func play(password: Bool) {
        refresh()
        policyLock.lock(); let current = generation, eligible = allowed; policyLock.unlock()
        guard eligible else { return }
        enqueue { [weak self] in self?.perform(password: password, generation: current) }
    }
    func stop() { started = false; refresh() }
    func shutdown() { stop(); flush() }
    private func current(_ value: UInt64) -> Bool {
        policyLock.lock(); defer { policyLock.unlock() }
        return allowed && generation == value
    }
    private func perform(password: Bool?, generation current: UInt64) {
        guard self.current(current) else { return }
        if cache == nil { cache = load() }
        guard self.current(current), let cache else { return }
        let keys = cache.keys
        guard !keys.isEmpty else { return }
        policyLock.lock(); let existing = output; policyLock.unlock()
        if let existing, existing.isRunning {
            policyLock.lock(); defer { policyLock.unlock() }
            guard allowed, generation == current, output === existing else { return }
            enqueueClick(existing, keys: keys, password: password)
            return
        }
        if let existing {
            policyLock.lock()
            let ownsRetirement = output === existing
            if ownsRetirement { output = nil; existing.setEnabled(false) }
            policyLock.unlock()
            if ownsRetirement { existing.stop() }
        }
        let now = clock()
        guard retryAt.map({ now >= $0 }) ?? true, self.current(current) else { return }
        retryAt = now + Self.retryInterval
        guard let created = try? makeOutput(cache) else { return }
        // A mute during decoding or construction cannot start the output. A mute during
        // start still sees an initially silent mixer until this final policy check.
        guard self.current(current) else { created.stop(); return }
        do { try created.start() } catch { created.stop(); return }
        guard created.isRunning else { created.stop(); return }
        policyLock.lock()
        guard allowed, generation == current else { policyLock.unlock(); created.stop(); return }
        output = created
        created.setEnabled(true)
        enqueueClick(created, keys: keys, password: password)
        policyLock.unlock()
    }
    private func enqueueClick(_ output: TypingSoundOutput, keys: [Int], password: Bool?) {
        guard let password else { return }
        let choice = choose(keys.count)
        guard keys.indices.contains(choice) else { return }
        output.enqueue(key: keys[choice], password: password)
    }
}
