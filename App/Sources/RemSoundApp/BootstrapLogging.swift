import Foundation
import RemSoundRuntime

enum BootstrapLogging {
    static func output(for options: LaunchOptions,
        store: () throws -> SettingsStore) throws -> String? {
        guard let enabled = options.diagnosticLoggingEnabled else { return nil }
        guard DiagnosticLoggingPreferences.setEnabled(enabled, in: try store()) else {
            throw RuntimeConfigurationError.invalidSettings
        }
        return "This computer's RemSound diagnostic logging is now \(enabled ? "ON" : "OFF") for the next launch. Existing log files are retained.\n"
    }
}
