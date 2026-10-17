import Foundation

// Keep an active audio session responsive when its window is hidden, while
// leaving the user's normal system and display sleep policy intact.
final class SessionActivity {
    private let begin: (ProcessInfo.ActivityOptions, String) -> NSObjectProtocol
    private let end: (NSObjectProtocol) -> Void
    private var token: NSObjectProtocol?

    init(begin: @escaping (ProcessInfo.ActivityOptions, String) -> NSObjectProtocol = {
        ProcessInfo.processInfo.beginActivity(options: $0, reason: $1)
    }, end: @escaping (NSObjectProtocol) -> Void = { ProcessInfo.processInfo.endActivity($0) }) {
        self.begin = begin
        self.end = end
    }

    func start() {
        guard token == nil else { return }
        token = begin(.userInitiatedAllowingIdleSystemSleep, "RemSound audio session")
    }

    func stop() {
        guard let active = token else { return }
        token = nil
        end(active)
    }

    deinit { stop() }
}
