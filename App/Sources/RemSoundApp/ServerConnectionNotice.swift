import Foundation
import RemSoundRuntime

@MainActor
protocol ServerNoticePresentation: AnyObject {
    func present()
    func retire()
    func showError(_ message: String)
}
@MainActor
final class ServerConnectionNotice {
    static let settingsKey = "RemSoundServerNoticeHidden"
    static let message = "Please note: when you connect to a server, you will only be able to see and connect to users on the server who have the same password as the one set in your profile."
    private let settings: SettingsStore
    private let unattended: () -> Bool, allowed: () -> Bool
    private let log: (String) -> Void
    private let makeDialog: (@escaping (Bool) -> Void) -> ServerNoticePresentation
    private var current: Visit?, generation: UUID?, closed = false
    private final class Visit {
        let completion: () -> Void
        let id = UUID()
        var dialog: ServerNoticePresentation?, response: Bool?, prepared = false, retired = false
        init(_ completion: @escaping () -> Void) { self.completion = completion }
    }
    init(settings: SettingsStore, unattended: @escaping () -> Bool, allowed: @escaping () -> Bool,
        log: @escaping (String) -> Void,
        makeDialog: ((@escaping (Bool) -> Void) -> ServerNoticePresentation)? = nil) {
        self.settings = settings; self.unattended = unattended; self.allowed = allowed; self.log = log
        self.makeDialog = makeDialog ?? { ServerConnectionNoticeWindow(answer: $0) }
    }
    deinit { MainActor.assumeIsolated { current?.retired = true; current?.dialog?.retire() } }
    func begin(_ completion: @escaping () -> Void) {
        guard !closed else { return }
        invalidate()
        let visit = Visit(completion); current = visit; generation = visit.id
        if settings.bool(forKey: Self.settingsKey) { finish(visit); return }
        if unattended() || !allowed() {
            log("Server notice: " + Self.message); finish(visit); return
        }
        let dialog = makeDialog { [weak self, weak visit] response in
            guard let self, let visit, self.current === visit, !visit.retired, !self.closed, visit.response == nil else { return }
            visit.response = response
            if visit.prepared { self.accept(visit) }
        }
        visit.dialog = dialog; visit.prepared = true
        guard current === visit, !visit.retired, !closed else { dialog.retire(); return }
        guard !unattended(), allowed() else {
            log("Server notice: " + Self.message); finish(visit); return
        }
        if visit.response != nil { accept(visit) } else { dialog.present() }
    }
    private func accept(_ visit: Visit) {
        guard current === visit, !visit.retired, !closed, let response = visit.response else { return }
        visit.response = nil
        if response, !settings.setValues([Self.settingsKey: true]) {
            let error = "Could not save the notice choice. Try OK again, or uncheck Don't show this message again."
            log(error); visit.dialog?.showError(error); return
        }
        finish(visit)
    }
    private func finish(_ visit: Visit) {
        guard current === visit, !visit.retired, !closed else { return }
        current = nil; visit.retired = true
        let dialog = visit.dialog; visit.dialog = nil
        dialog?.retire()
        guard !closed, generation == visit.id else { return }
        generation = nil
        visit.completion()
    }
    func invalidate() {
        generation = nil
        guard let visit = current else { return }
        current = nil; visit.retired = true; let dialog = visit.dialog; visit.dialog = nil; dialog?.retire()
    }
    func shutdown() { closed = true; invalidate() }
}
