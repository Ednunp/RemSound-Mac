import AppKit
import Foundation
import RemSoundCore
import RemSoundJam

/// Checking for, and installing, a newer RemSound Mac (Windows MainForm's updater). Three ways in, as on Windows: a check
/// you ask for, the check when RemSound opens, and the background check every so often (Preferences). The last two are
/// automatic: when the install time range is on, an update they find outside it waits until the range opens. A silent
/// install found at opening first shows a short notice - Install Now, Postpone or Skip - that installs by itself after
/// eight seconds, so you know why RemSound is about to close. The question before an install carries the release notes.
@MainActor
final class UpdateService {
    enum Origin: String { case manual, startup, background }

    private var checking = false
    var onPrepared: ((URL, String, URL) -> Void)?
    /// The updater's lines for the log.
    var log: ((String) -> Void)?
    /// Whether to install without asking, decided when a check runs (off while RemSound is running a session).
    var installSilently: (() -> Bool)?
    private var backgroundTimer: Timer?
    private var deferredTimer: Timer?
    static let noticeSeconds = 8
    static let handedOffKey = "RemSoundUpdateHandedOffVersion"
    static let handedOffNotesKey = "RemSoundUpdateHandedOffNotes"
    static let whatsNewKey = "RemSoundShowWhatsNewAfterUpdate"

    /// The background check, every so often as Preferences says; Never stops it.
    func scheduleBackgroundChecks() {
        backgroundTimer?.invalidate(); backgroundTimer = nil
        let stored = AppRuntime.settings.object(forKey: UpdateCheckFrequency.settingsKey) as? Int
        let frequency = stored.flatMap(UpdateCheckFrequency.init(rawValue:)) ?? .default
        guard AppRuntime.configuration.allowsUpdates, let interval = frequency.interval else { return }
        backgroundTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check(.background) }
        }
    }

    /// An automatic check found an update outside the install time range: not now, but again shortly after it opens.
    private func deferredByWindow(_ version: String, _ origin: Origin) -> Bool {
        guard origin != .manual, AppRuntime.settings.bool(forKey: UpdateWindow.enabledKey) else { return false }
        let start = AppRuntime.settings.object(forKey: UpdateWindow.startKey) as? Int ?? UpdateWindow.defaultStart
        let end = AppRuntime.settings.object(forKey: UpdateWindow.endKey) as? Int ?? UpdateWindow.defaultEnd
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: Date())
        let seconds = TimeInterval((parts.hour ?? 0) * 3_600 + (parts.minute ?? 0) * 60 + (parts.second ?? 0))
        guard !UpdateWindow.isWithin(minutesOfDay: Int(seconds) / 60, start: start, end: end) else { return false }
        let wait = max(60, UpdateWindow.untilNextStart(secondsOfDay: seconds, start: start) + 60)
        deferredTimer?.invalidate()
        deferredTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.log?("updater: install time range opened - checking again for the deferred update")
                self?.check(.background)
            }
        }
        log?("updater: \(origin.rawValue) check found \(version), but it's outside the install time range "
            + "(\(UpdateWindow.format(start))-\(UpdateWindow.format(end))) - deferred; checking again in \(Int(wait / 60)) min")
        return true
    }

    func check(manual: Bool, installSilently: Bool) { check(manual ? .manual : .startup, silently: installSilently) }

    func check(_ origin: Origin, silently: Bool? = nil) {
        guard AppRuntime.configuration.allowsUpdates else { return }
        guard !checking else { return }
        checking = true
        let manual = origin == .manual
        let installSilently = !manual && (silently ?? self.installSilently?() ?? false)
        Task {
            defer { checking = false }
            do {
                var request = URLRequest(url: UpdateCatalog.releasesURL,
                    cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
                request.setValue("RemSound Mac updater", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw UpdateServiceError.failed("The Mac release list is unavailable.")
                }
                let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "0.0.0"
                guard let candidate = try UpdateCatalog.newest(in: data, newerThan: current) else {
                    log?("updater: \(origin.rawValue) check - up to date (\(current))")
                    if manual { showAlert("RemSound Is Up to Date", "Installed version: \(current)") }
                    return
                }
                log?("updater: \(origin.rawValue) check found \(candidate.version)")
                if deferredByWindow(candidate.version, origin) { return }
                CueSounds.shared.play(.update)
                if installSilently && origin == .startup {
                    switch notice(candidate) {
                    case .install: break
                    case .postpone: log?("updater: postponed \(candidate.version) from the notice"); return
                    case .skip: log?("updater: skipped \(candidate.version) from the notice"); return
                    }
                } else if !installSilently {
                    guard confirm(candidate) else { return }
                }
                try await downloadAndInstall(candidate)
            } catch {
                log?("updater: \(origin.rawValue) check failed: \(error.localizedDescription)")
                if manual || installSilently {
                    showAlert("RemSound Update Failed", error.localizedDescription)
                }
            }
        }
    }

    private func confirm(_ candidate: UpdateCatalog.Candidate) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Update available"
        alert.informativeText = ReleaseNotesText.question(version: candidate.version, notes: candidate.notes)
            + "\n\nSave your DAW projects first; an open DAW loads the new plugin after it restarts."
        alert.addButton(withTitle: "Install Update")
        alert.addButton(withTitle: "Later")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private enum NoticeChoice { case install, postpone, skip }

    /// Before a silent install found as RemSound opens (Windows UpdateInstallNoticeDialog): what is about to happen and
    /// why RemSound will close, installing by itself after eight seconds unless you choose otherwise.
    private func notice(_ candidate: UpdateCatalog.Candidate) -> NoticeChoice {
        let alert = NSAlert()
        alert.messageText = "Installing RemSound update"
        alert.informativeText = "RemSound Mac \(candidate.version) installs in \(Self.noticeSeconds) seconds. RemSound will close and open again."
        alert.addButton(withTitle: "Install Now")
        alert.addButton(withTitle: "Postpone")
        alert.addButton(withTitle: "Skip This Version")
        let timer = Timer(timeInterval: TimeInterval(Self.noticeSeconds), repeats: false) { _ in
            MainActor.assumeIsolated { NSApp.stopModal(withCode: .alertFirstButtonReturn) }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        let answer = alert.runModal()
        timer.invalidate()
        switch answer {
        case .alertFirstButtonReturn: return .install
        case .alertThirdButtonReturn: return .skip
        default: return .postpone
        }
    }

    /// After an update this app handed off, on its first run (Windows MaybeShowWhatsNewAfterUpdate): the new version's
    /// notes, once, unless turned off in Preferences. The marker is kept only by a hand-off, so an ordinary start never
    /// shows it.
    func showWhatsNewIfJustUpdated() {
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard let handedOff = AppRuntime.settings.string(forKey: Self.handedOffKey), handedOff == current else { return }
        let notes = AppRuntime.settings.string(forKey: Self.handedOffNotesKey) ?? ""
        AppRuntime.settings.removeObject(forKey: Self.handedOffKey)
        AppRuntime.settings.removeObject(forKey: Self.handedOffNotesKey)
        log?("updater: first run after updating to \(current)")
        let show = AppRuntime.settings.object(forKey: Self.whatsNewKey) as? Bool ?? true
        guard show, !AppRuntime.configuration.silent else { return }
        showAlert("What's new in RemSound Mac \(current)",
                  notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "RemSound Mac \(current) is installed." : notes)
    }

    private func downloadAndInstall(_ candidate: UpdateCatalog.Candidate) async throws {
        let installedApp = URL(fileURLWithPath: "/Applications/RemSound.app")
        guard Bundle.main.bundleURL.standardizedFileURL == installedApp.standardizedFileURL else {
            throw UpdateServiceError.failed("Move RemSound.app to Applications before updating it.")
        }
        let stage = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/RemSound/Updates/update-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stage.path)
        var handedOff = false
        defer { if !handedOff { try? FileManager.default.removeItem(at: stage) } }

        var request = URLRequest(url: candidate.downloadURL,
            cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        request.setValue("RemSound Mac updater", forHTTPHeaderField: "User-Agent")
        let (download, response) = try await URLSession.shared.download(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateServiceError.failed("The update download did not complete.")
        }
        let zip = stage.appendingPathComponent(candidate.assetName)
        try FileManager.default.moveItem(at: download, to: zip)
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/RemSoundUpdater")
        try await Task.detached(priority: .userInitiated) {
            try Self.runHelper(helper, ["--prepare", zip.path, stage.path, candidate.version],
                wait: true)
        }.value
        guard let onPrepared else {
            throw UpdateServiceError.failed("The app could not hand off the verified update.")
        }
        handedOff = true
        AppRuntime.settings.set(candidate.version, forKey: Self.handedOffKey)
        AppRuntime.settings.set(candidate.notes, forKey: Self.handedOffNotesKey)
        onPrepared(stage, candidate.version, helper)
    }

    func launchInstaller(stage: URL, version: String, helper: URL) throws {
        try Self.runHelper(helper, ["--install", stage.path, version,
            String(ProcessInfo.processInfo.processIdentifier)], wait: false)
    }

    nonisolated private static func runHelper(_ executable: URL, _ arguments: [String],
        wait: Bool) throws {
        if wait {
            // The helper has a six-minute operation budget; allow it to clean up its own child first.
            _ = try UpdateCommand.run(executable: executable, arguments: arguments,
                timeout: UpdateCommand.preparationTimeout)
        } else {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let logs = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/RemSound", isDirectory: true)
            var handle: FileHandle?
            if (try? FileManager.default.createDirectory(at: logs,
                withIntermediateDirectories: true)) != nil {
                let log = logs.appendingPathComponent("Update.log")
                if FileManager.default.createFile(atPath: log.path, contents: nil)
                    || FileManager.default.fileExists(atPath: log.path) {
                    handle = try? FileHandle(forWritingTo: log)
                    try? handle?.truncate(atOffset: 0)
                }
            }
            process.standardOutput = handle ?? FileHandle.nullDevice
            process.standardError = handle ?? FileHandle.nullDevice
            try process.run()
            try? handle?.close()
        }
    }

    private func showAlert(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }
}

private enum UpdateServiceError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self { case .failed(let detail): detail }
    }
}
