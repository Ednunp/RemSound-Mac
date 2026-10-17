import Foundation
import RemSoundRuntime

extension ProductTestPack {
    static let pluginInstall = "Plugin install/remove is per-user and exact (other plugins untouched)"
    static func checkPluginInstallation() -> Step {
        var count = 0, failures = [String]()
        func require(_ condition: Bool, _ code: String) { count += 1; if !condition { failures.append(code) } }
        let parent = ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let root = parent.appendingPathComponent("plugin-transaction-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let home = root.appendingPathComponent("owned-home")
            let targets = ["Components/RemSound.component", "VST3/RemSound.vst3", "CLAP/RemSound.clap"].map {
                home.appendingPathComponent("Library/Audio/Plug-Ins/" + $0)
            }
            let sources = UpdateArchive.bundleNames.dropFirst().map { root.appendingPathComponent($0) }
            let items = zip(sources, targets).map { UpdateInstallItem(source: $0, target: $1) }
            for item in try RuntimeConfiguration.pluginStatusForListing(root: home).items {
                require(item.state == .missing, "plugin.initial-absence")
            }
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let neighbors = targets.map { $0.deletingLastPathComponent().appendingPathComponent("AnotherVendor.synthetic") }
            for url in neighbors {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("neighbor must survive".utf8).write(to: url)
            }
            let settings = home.appendingPathComponent("settings.plist"), sentinel = Data("unparsed private settings sentinel".utf8)
            try sentinel.write(to: settings)
            func version(_ url: URL) throws -> String? {
                let data = try Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
                return (try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])?["CFBundleShortVersionString"] as? String
            }
            func prepare(_ value: String) throws {
                for source in sources {
                    for path in ["Contents/MacOS", "Contents/Frameworks"] {
                        try FileManager.default.createDirectory(at: source.appendingPathComponent(path), withIntermediateDirectories: true)
                    }
                    let info = ["CFBundleIdentifier": "org.remsound.plugin", "CFBundleExecutable": "RemSound",
                        "CFBundleShortVersionString": value, "CFBundleVersion": "1"]
                    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                        .write(to: source.appendingPathComponent("Contents/Info.plist"))
                    let binary = source.appendingPathComponent("Contents/MacOS/RemSound")
                    try Data("synthetic non-native fixture; never execute".utf8).write(to: binary)
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
                    try Data([1]).write(to: source.appendingPathComponent("Contents/Frameworks/libRemSoundPluginHost-v1.dylib"))
                }
            }
            try prepare("1.2.3")
            try UpdateTransaction.install(items, copy: FileManager.default.copyItem,
                verify: { if try version($0) != "1.2.3" { throw CocoaError(.fileReadCorruptFile) } })
            for item in try RuntimeConfiguration.pluginStatusForListing(root: home).items {
                require(item.state == .metadataPresent && item.version == "1.2.3", "plugin.actual-transaction-installed")
            }
            for neighbor in neighbors { require(try Data(contentsOf: neighbor) == Data("neighbor must survive".utf8), "plugin.neighbor-preserved") }
            require(try Data(contentsOf: settings) == sentinel, "plugin.settings-unread-unchanged")
            try prepare("1.2.4")
            try UpdateTransaction.install(items, copy: FileManager.default.copyItem,
                verify: { if try version($0) != "1.2.4" { throw CocoaError(.fileReadCorruptFile) } })
            for target in targets { require(try version(target) == "1.2.4", "plugin.reinstall-refresh") }
            try FileManager.default.removeItem(at: targets[2])
            try prepare("1.2.5")
            var refused = false
            do {
                try UpdateTransaction.install(items, copy: FileManager.default.copyItem,
                    verify: { if $0 == targets[1] { throw CocoaError(.fileReadCorruptFile) } })
            } catch { refused = true }
            require(refused, "plugin.failed-final-verification")
            require(!FileManager.default.fileExists(atPath: targets[2].path), "plugin.rollback-restores-absence")
            for target in targets.prefix(2) { require(try version(target) == "1.2.4", "plugin.rollback-restores-old") }
            for neighbor in neighbors { require(try Data(contentsOf: neighbor) == Data("neighbor must survive".utf8), "plugin.rollback-neighbor") }
            require(try Data(contentsOf: settings) == sentinel, "plugin.rollback-settings")
            // Exercise the consumed CLI command's same fixed ownership path, not a standalone copier.
            let commandHome = root.appendingPathComponent("command-home")
            try FileManager.default.createDirectory(at: commandHome, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for (format, source) in zip(["AU", "VST3", "CLAP"], sources) {
                let destination = commandHome.appendingPathComponent("plugin-payload/" + format + "/" + source.lastPathComponent)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: destination)
            }
            let installed = PluginInstallationCommand.run(action: .install, isolatedRoot: commandHome)
            require(installed.status == "installed" && installed.files == 9, "plugin.command-fixed-install")
            require(!installed.nativeActivationVerified && installed.scope == "isolated", "plugin.command-no-native-claim")
            let commandSettings = commandHome.appendingPathComponent("settings.plist")
            try sentinel.write(to: commandSettings)
            let commandBundle = commandHome.appendingPathComponent("Library/Audio/Plug-Ins/VST3/RemSound.vst3")
            let bystander = commandBundle.appendingPathComponent("Contents/other-owner.txt")
            try Data("not owned by command".utf8).write(to: bystander)
            require(PluginInstallationCommand.run(action: .install, isolatedRoot: commandHome).status == "installed", "plugin.command-reinstall")
            let removed = PluginInstallationCommand.run(action: .remove, isolatedRoot: commandHome)
            require(removed.status == "removed" && removed.files == 9, "plugin.command-exact-remove")
            require(!FileManager.default.fileExists(atPath: commandBundle.appendingPathComponent("Contents/Info.plist").path), "plugin.command-owned-gone")
            require(try Data(contentsOf: bystander) == Data("not owned by command".utf8), "plugin.command-bystander-survives")
            require(try Data(contentsOf: commandSettings) == sentinel, "plugin.command-settings-unchanged")
            require(PluginInstallationCommand.run(action: .remove, isolatedRoot: commandHome).status == "notInstalled", "plugin.command-absent-truthful")
            require(PluginInstallationCommand.run(action: .install, isolatedRoot: nil).status == "unsupported", "plugin.command-normal-off")
        } catch { failures.append("plugin-isolated-transaction-failed") }
        let passed = failures.isEmpty
        failures.append("plugin-normal-package-native-menu-custom-path-and-signature-acceptance-unverified")
        return .init(name: pluginInstall, status: passed ? "UNVERIFIED" : "FAIL", assertions: count, failures: failures)
    }
}
