import AppKit
import Foundation
import Darwin
import RemSoundCore

private enum UpdateFailure: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}

private enum Updater {
    static let teamID = "83NN3HS237"
    static let bundleNames = UpdateArchive.bundleNames
    static let bundleIDs = ["org.remsound.mac", "org.remsound.plugin",
        "org.remsound.plugin", "org.remsound.plugin"]
    static let cacheRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/RemSound/Updates", isDirectory: true)
    static let targetApp = URL(fileURLWithPath: "/Applications/RemSound.app")
    static let operationDeadline = ProcessInfo.processInfo.systemUptime + UpdateCommand.helperOperationTimeout
    static var installationRecoveryNeeded = false
    static func payloadName(_ version: String) throws -> String { try UpdateArchive.payloadName(for: version) }

    static func run(_ tool: String, _ args: [String], maxOutput: Int = 1_000_000) throws -> String {
        let remaining = operationDeadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw UpdateFailure.invalid("The update operation timed out.") }
        let started = ProcessInfo.processInfo.systemUptime
        let name = URL(fileURLWithPath: tool).lastPathComponent
        print("Update command: \(name) \(args)")
        do {
            let output = try UpdateCommand.run(executable: URL(fileURLWithPath: tool), arguments: args,
                timeout: min(UpdateCommand.defaultTimeout, remaining), maxOutput: maxOutput)
            print("Update command finished: \(name), exit 0, \(String(format: "%.2f", ProcessInfo.processInfo.systemUptime - started)) seconds.")
            if !output.isEmpty { print(String(output.prefix(2_000))) }
            return output
        } catch {
            fputs("Update command failed: \(name), \(error.localizedDescription)\n", stderr)
            throw error
        }
    }

    static func inCache(_ stage: URL) -> Bool {
        let root = cacheRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let path = stage.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(root + "/") && stage.lastPathComponent.hasPrefix("update-")
    }

    static func verifyBundles(_ folder: URL, version: String) throws {
        for (index, name) in bundleNames.enumerated() {
            let url = folder.appendingPathComponent(name)
            try verify(url, version: version, bundleID: bundleIDs[index], isApp: index == 0)
        }
    }

    static func verify(_ url: URL, version: String, bundleID: String, isApp: Bool) throws {
        guard let bundle = Bundle(url: url), bundle.bundleIdentifier == bundleID,
            bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version else {
            throw UpdateFailure.invalid("The update contains the wrong bundle or version: \(url.lastPathComponent).")
        }
        let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and identifier \"\(bundleID)\""
        _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict",
            "--test-requirement", "=" + requirement, url.path])
        _ = try run("/usr/bin/xcrun", ["stapler", "validate", url.path])
        if isApp {
            _ = try run("/usr/sbin/spctl", ["--assess", "--type", "execute", url.path])
        }
        let executable = url.appendingPathComponent("Contents/MacOS/RemSound")
        for architecture in ["arm64", "x86_64"] {
            _ = try run("/usr/bin/lipo", ["-verify_arch", architecture, executable.path])
        }
    }

    static func prepare(zip: URL, stage: URL, version: String) throws {
        guard inCache(stage), zip.deletingLastPathComponent().standardizedFileURL == stage.standardizedFileURL else {
            throw UpdateFailure.invalid("The update must be staged in the RemSound cache.")
        }
        let extract = stage.appendingPathComponent("extract", isDirectory: true)
        let remaining = operationDeadline - ProcessInfo.processInfo.systemUptime
        try UpdateArchive.extract(zip: zip, to: extract, version: version, timeout: remaining)
        try verifyBundles(extract.appendingPathComponent(try payloadName(version)), version: version)
    }

    static func install(stage: URL, version: String, oldPID: Int32) throws {
        _ = try payloadName(version)
        guard inCache(stage), oldPID > 0, targetApp.standardizedFileURL.path == "/Applications/RemSound.app" else {
            throw UpdateFailure.invalid("The update target is invalid.")
        }
        var exited = false
        for _ in 0..<100 {
            if kill(oldPID, 0) != 0 { exited = true; break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        guard exited else { throw UpdateFailure.invalid("RemSound did not exit; nothing was replaced.") }
        installationRecoveryNeeded = true
        let extract = stage.appendingPathComponent("extract")
            .appendingPathComponent(try payloadName(version), isDirectory: true)
        try verifyBundles(extract, version: version)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let targets = [targetApp,
            home.appendingPathComponent("Library/Audio/Plug-Ins/Components/RemSound.component"),
            home.appendingPathComponent("Library/Audio/Plug-Ins/VST3/RemSound.vst3"),
            home.appendingPathComponent("Library/Audio/Plug-Ins/CLAP/RemSound.clap")]
        let items = zip(bundleNames, targets).map { pair in
            UpdateInstallItem(source: extract.appendingPathComponent(pair.0), target: pair.1)
        }
        try UpdateTransaction.install(items, copy: { source, target in
            _ = try run("/usr/bin/ditto", [source.path, target.path])
        }, verify: { url in
            guard let index = targets.firstIndex(where: {
                $0 == url || url.path.hasPrefix($0.deletingPathExtension().path + ".new-")
            }) else {
                throw UpdateFailure.invalid("An unexpected update target was selected.")
            }
            try verify(url, version: version, bundleID: bundleIDs[index], isApp: index == 0)
        })
        try? FileManager.default.removeItem(at: stage)
        do { try reopen() }
        catch {
            throw UpdateFailure.invalid("The update installed, but RemSound could not reopen automatically. Open it from Applications.")
        }
    }

    static func reopen() throws {
        _ = try UpdateCommand.run(executable: URL(fileURLWithPath: "/usr/bin/open"),
            arguments: [targetApp.path], timeout: 10)
    }

    static func alert(_ detail: String) {
        // Human-facing failure text has no timeout and needs no AppleScript string construction.
        let application = NSApplication.shared
        _ = application.setActivationPolicy(.accessory)
        application.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "RemSound Update Failed"
        alert.informativeText = detail
        alert.runModal()
    }
}

let args = CommandLine.arguments
do {
    guard args.count >= 2 else { throw UpdateFailure.invalid("Missing update command.") }
    switch args[1] {
    case "--prepare" where args.count == 5:
        try Updater.prepare(zip: URL(fileURLWithPath: args[2]),
            stage: URL(fileURLWithPath: args[3]), version: args[4])
        print("Update package verified.")
    case "--install" where args.count == 5:
        guard let pid = Int32(args[4]) else { throw UpdateFailure.invalid("Invalid app process ID.") }
        try Updater.install(stage: URL(fileURLWithPath: args[2]), version: args[3], oldPID: pid)
        print("Update installed.")
    default:
        throw UpdateFailure.invalid("Unknown update command.")
    }
} catch {
    let detail = error.localizedDescription
    fputs("RemSound update failed: \(detail)\n", stderr)
    if args.count > 1 && args[1] == "--install" && Updater.installationRecoveryNeeded {
        if args.count > 2 {
            let stage = URL(fileURLWithPath: args[2])
            if Updater.inCache(stage) { try? FileManager.default.removeItem(at: stage) }
        }
        if FileManager.default.fileExists(atPath: Updater.targetApp.path) {
            try? Updater.reopen()
        }
        Updater.alert(detail)
    }
    exit(1)
}
