import Foundation
import RemSoundCore
import RemSoundRuntime

// Bootstrap installs this before SwiftUI can construct the delegate or its stored properties.
enum AppRuntime {
    static private(set) var configuration: RuntimeConfiguration!
    static private(set) var startup = StartupOptions()
    static private(set) var startHidden = false
    static func hidesStartupWindow(_ options:LaunchOptions) -> Bool {
        if options.checkAccessibility { return false }
        return options.startup.startMinimized || options.silent || options.headless
    }
    static var settings: SettingsStore { configuration.settings }
    private static let profilePasswords = ProfilePasswordStores()

    static func prepare(_ options: LaunchOptions) throws {
        precondition(configuration == nil)
        configuration = try RuntimeConfiguration(options: options)
        startup = options.startup
        startHidden = hidesStartupWindow(options)
            // Preferences' "Start hidden in the menu bar" (Windows StartMinimised), never for the accessibility check.
            || (!options.checkAccessibility && configuration.settings.object(forKey: "RemSoundStartMinimised") as? Bool == true)
        if !configuration.isIsolated {
            PluginHelpRuntimeState.begin(settings: settings, silent: configuration.silent,
                processID: ProcessInfo.processInfo.processIdentifier)
        }
    }
    static func finish() {
        guard !configuration.isIsolated else { return }
        PluginHelpRuntimeState.end(settings: settings, processID: ProcessInfo.processInfo.processIdentifier)
    }
    static func passwordStore(account: String = "default", role: ProfilePasswordStores.Role = .audio) -> PasswordStore {
        profilePasswords.store(account: account, role: role, isolated: configuration.isIsolated)
    }
}
