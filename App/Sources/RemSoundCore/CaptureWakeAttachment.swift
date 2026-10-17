import AudioSupport
import Foundation

// Serial owner controls lifetime. The callback receives only the immutable raw
// pointer; its native registration/whole-callback lease supplies quiescence.
final class CaptureWakeAttachment {
    private let owner: DispatchQueue
    private var raw: OpaquePointer?
    private var reader: DispatchSourceRead?
    private var enabledFrames = 0
    private(set) var retired = false
    private var producerStopped = false, readerCancelled = false
    private var reportedBusy = false
    private var finalSnapshot = RSCaptureWakeSnapshot()
    private let ready: () -> Void
    private let observed: ((RSCaptureWakeSnapshot) -> Void)?
    private let finished: (Bool) -> Void
    private let noteFailure: (String) -> Void

    init?(owner: DispatchQueue, ready: @escaping () -> Void,
        observed: ((RSCaptureWakeSnapshot) -> Void)? = nil,
        finished: @escaping (Bool) -> Void = { _ in },
        noteFailure: @escaping (String) -> Void = { _ in }) {
        dispatchPrecondition(condition: .onQueue(owner))
        guard let raw = rs_capture_wake_create() else { return nil }
        self.owner = owner
        self.raw = raw
        self.ready = ready
        self.observed = observed
        self.finished = finished
        self.noteFailure = noteFailure
        let source = DispatchSource.makeReadSource(fileDescriptor: rs_capture_wake_read_fd(raw), queue: owner)
        reader = source
        source.setEventHandler { [weak self] in
            guard let self, !self.retired, let raw = self.raw else { return }
            if rs_capture_wake_consume(raw) > 0 {
                self.observed?(rs_capture_wake_snapshot(raw))
                self.ready()
            }
        }
        // Hold the context until cancellation has drained all queued consumers.
        source.setCancelHandler { [self] in
            readerCancelled = true
            finishIfQuiescent()
        }
        source.resume()
    }
    var producer: OpaquePointer? {
        dispatchPrecondition(condition: .onQueue(owner))
        return raw
    }
    func configure(packetFrames: Int, sending: Bool, hasDestination: Bool,
        pushDriven: Bool, sourceCount: Int) {
        dispatchPrecondition(condition: .onQueue(owner))
        guard !retired, let raw else { return }
        let frames = sending && hasDestination && pushDriven && sourceCount == 1 ? max(0, packetFrames) : 0
        guard frames != enabledFrames else { return }
        enabledFrames = frames
        _ = rs_capture_wake_configure(raw, frames)
    }
    func snapshot() -> RSCaptureWakeSnapshot {
        dispatchPrecondition(condition: .onQueue(owner))
        return raw.map(rs_capture_wake_snapshot) ?? finalSnapshot
    }
    var disposed: Bool {
        dispatchPrecondition(condition: .onQueue(owner))
        return raw == nil
    }
    func retire(producersStopped: Bool) {
        dispatchPrecondition(condition: .onQueue(owner))
        producerStopped = producerStopped || producersStopped
        if !retired {
            retired = true
            enabledFrames = 0
            if let raw { _ = rs_capture_wake_configure(raw, 0) }
            reader?.cancel()
            reader = nil
        }
        finishIfQuiescent()
    }
    @discardableResult
    func poll(producersStopped: Bool) -> Bool {
        dispatchPrecondition(condition: .onQueue(owner))
        if retired { producerStopped = producerStopped || producersStopped }
        finishIfQuiescent()
        return raw == nil
    }
    private func finishIfQuiescent() {
        guard retired, producerStopped, readerCancelled, let raw else { return }
        guard rs_capture_wake_close(raw) == 1 else {
            if !reportedBusy {
                reportedBusy = true
                noteFailure("Capture notification still has an entered producer; retaining its context.")
            }
            return // Existing session cleanup timer retries; never free uncertain memory.
        }
        finalSnapshot = rs_capture_wake_snapshot(raw)
        guard rs_capture_wake_destroy(raw) == 1 else {
            if !reportedBusy {
                reportedBusy = true
                noteFailure("Capture notification disposal is busy; retaining its context.")
            }
            return
        }
        self.raw = nil
        if finalSnapshot.errors > 0 {
            noteFailure("Capture notification retired with \(finalSnapshot.errors) notification errors; the timer fallback remained available.")
        }
        finished(finalSnapshot.errors == 0)
    }
    // No speculative deinit free or lifetime assertion. The session retains an
    // unresolved context until both barriers complete, including error paths.
}
