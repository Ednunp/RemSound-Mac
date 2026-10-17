import AppKit
import RemSoundRuntime

enum BootstrapControlSpecifications {
    static let permission = "REMSOUND_TEST_NATIVE_CONTROL_SPECIFICATIONS"
    static func accepts(root: URL?, environment: [String: String]) -> Bool {
        BootstrapProfileLogging.accepts(root: root, environment: environment, permission: permission)
    }
    static func run(for options: LaunchOptions) -> (assertions: Int, failures: [String])? {
        guard accepts(root: options.configurationDirectory, environment: ProcessInfo.processInfo.environment),
            Thread.isMainThread, AppRuntime.configuration == nil, let root = options.configurationDirectory else { return nil }
        do {
            try AppRuntime.prepare(LaunchOptions.parse(["--config-dir", root.path, "--headless", "--silent"]))
            return MainActor.assumeIsolated {
                _ = NSApplication.shared
                return AppDelegate.controlSpecificationsProductCheck()
            }
        } catch { return (1, ["controls.native.isolated-configuration-failed"]) }
    }
}
