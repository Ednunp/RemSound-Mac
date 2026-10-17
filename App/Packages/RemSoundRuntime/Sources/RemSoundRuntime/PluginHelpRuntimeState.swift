import Foundation

/// Global Help cues can also play while the companion is stopped or closed. A live silent launch overrides them.
public enum PluginHelpRuntimeState {
    public static let silentProcessKey = "pluginHelpSilentPID"
    public static let preferencesAvailableKey = "pluginHelpPreferencesAvailable"

    public static func begin(settings: SettingsStore, silent: Bool, processID: Int32) {
        settings.set(true, forKey: preferencesAvailableKey)
        if silent && processID > 0 {
            settings.set(processID, forKey: silentProcessKey)
        } else {
            settings.removeObject(forKey: silentProcessKey)
        }
    }

    public static func end(settings: SettingsStore, processID: Int32) {
        guard settings.integer(forKey: silentProcessKey) == Int(processID) else { return }
        settings.removeObject(forKey: silentProcessKey)
    }
}
