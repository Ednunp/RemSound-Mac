import CoreFoundation
import Foundation

/// A machine choice. Older or malformed settings retain the Mac's existing logging behavior.
public enum DiagnosticLoggingPreferences {
    private static let enabledKey = "RemSoundDiagnosticLoggingEnabled"
    public static func enabled(in settings: SettingsStore) -> Bool {
        guard let number = settings.object(forKey: enabledKey) as? NSNumber,
            CFGetTypeID(number) == CFBooleanGetTypeID() else { return true }
        return number.boolValue
    }
    @discardableResult
    public static func setEnabled(_ enabled: Bool, in settings: SettingsStore) -> Bool {
        settings.setValues([enabledKey: enabled])
    }
}
