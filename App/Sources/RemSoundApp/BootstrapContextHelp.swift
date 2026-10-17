import AppKit
import RemSoundRuntime

enum BootstrapContextHelp {
    static let permission = "REMSOUND_TEST_NATIVE_CONTEXT_HELP"
    static func run(for options: LaunchOptions) -> (assertions: Int, failures: [String])? {
        guard BootstrapProfileLogging.accepts(root: options.configurationDirectory, environment: ProcessInfo.processInfo.environment, permission: permission),
            Thread.isMainThread, AppRuntime.configuration == nil, let root = options.configurationDirectory else { return nil }
        guard let manual = FocusedHelpContent.bundledManual() else { return (1, ["help.native.manual-unavailable"]) }
        do {
            try AppRuntime.prepare(LaunchOptions.parse(["--config-dir", root.path, "--headless", "--silent"]))
            return MainActor.assumeIsolated {
                _ = NSApplication.shared
                return AppDelegate.contextHelpProductCheck(manual: manual)
            }
        } catch { return (1, ["help.native.isolated-configuration-failed"]) }
    }
}
