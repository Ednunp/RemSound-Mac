import Foundation
import RemSoundCore

// One outstanding main-queue probe prevents a stalled UI from accumulating work.
// Both the observation model and bounded file writes belong to this serial worker.
final class UIResponsivenessMonitor {
    private let queue = DispatchQueue(label: "RemSound UI observations", qos: .utility)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var timer: DispatchSourceTimer?
    private var state = ResponsivenessDiagnostics()
    private var nextExpiry: TimeInterval = 0
    private let sink: ((String) -> Void)?
    private var enabled: Bool
    private var requested = false
    private let logURL: URL
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
    private static let maximumLogBytes = 131_072

    init(logURL: URL? = nil, sink: ((String) -> Void)? = nil, enabled: Bool = true) {
        self.logURL = logURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/RemSound/Responsiveness.log")
        self.enabled = enabled
        self.sink = sink
        queue.setSpecific(key: queueKey, value: 1)
    }
    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.requested = true
            self.startOnQueue()
        }
    }
    private func startOnQueue() {
        guard enabled, timer == nil else { return }
        state.reset()
        nextExpiry = 0
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }
    func setEnabled(_ value: Bool) {
        queue.sync {
            guard enabled != value else { return }
            stopOnQueue()
            enabled = value
            if requested { startOnQueue() }
        }
    }
    func stop() {
        let stop = { [self] in requested = false; stopOnQueue() }
        if DispatchQueue.getSpecific(key: queueKey) != nil { stop() }
        else { queue.sync(execute: stop) }
    }
    private func stopOnQueue() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        state.reset()
    }
    func begin(_ operation: ResponsivenessDiagnostics.Operation) -> UUID {
        let id = UUID(), began = ProcessInfo.processInfo.systemUptime
        queue.async { [weak self] in
            guard let self, self.timer != nil else { return }
            self.record(self.state.beginAction(id: id, operation: operation, at: began))
        }
        return id
    }
    func handlerReturned(_ id: UUID) {
        let at = ProcessInfo.processInfo.systemUptime
        queue.async { [weak self] in
            guard let self, self.timer != nil else { return }
            self.record(self.state.handlerReturned(id: id, at: at))
        }
    }
    func finish(_ id: UUID, outcome: ResponsivenessDiagnostics.ActionOutcome = .effectObserved) {
        let at = ProcessInfo.processInfo.systemUptime
        queue.async { [weak self] in
            guard let self, self.timer != nil else { return }
            self.record(self.state.finishAction(id: id, outcome: outcome, at: at))
        }
    }
    func endQuietScope(_ id: UUID) {
        let at = ProcessInfo.processInfo.systemUptime
        queue.async { [weak self] in
            guard let self, self.timer != nil else { return }
            let handler = self.state.handlerReturned(id: id, at: at)
            if let handler, handler.seconds > ResponsivenessDiagnostics.stallThresholdSeconds { self.record(handler) }
            _ = self.state.finishAction(id: id, outcome: .localStateOnly, at: at)
        }
    }
    private func tick() {
        guard timer != nil else { return }
        let at = ProcessInfo.processInfo.systemUptime
        record(state.poll(at: at))
        if at >= nextExpiry {
            for event in state.expireActions(at: at) { record(event) }
            nextExpiry = at + 1
        }
        let id = UUID()
        guard state.beginProbe(id: id, at: at) else { return }
        DispatchQueue.main.async { [weak self] in
            let completedAt = ProcessInfo.processInfo.systemUptime
            self?.queue.async { [weak self] in
                guard let self, self.timer != nil else { return }
                self.record(self.state.probeCompleted(id: id, at: completedAt))
            }
        }
    }
    private func record(_ event: ResponsivenessDiagnostics.Event?) {
        guard enabled, let event else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) RemSound \(version): \(event.description)\n"
        if let sink { sink(line); return }
        do {
            let files = FileManager.default
            try files.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = try? files.attributesOfItem(atPath: logURL.path)[.size] as? NSNumber,
               size.intValue > Self.maximumLogBytes {
                try Data().write(to: logURL, options: .atomic)
            }
            if !files.fileExists(atPath: logURL.path) { files.createFile(atPath: logURL.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {}
    }
    deinit { stop() }
}
