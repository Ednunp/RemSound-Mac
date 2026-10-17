import Foundation
import RemSoundRuntime

/// Uses the existing settings boundary for the currently opened profile's PTT choices.
public enum PushToTalkPreferences {
    static let settingsKey = "pushToTalk"
    static let maximumStoredBytes = 4_096
    private enum Failure: LocalizedError {
        case invalidStoredValue, persistenceFailed
        var errorDescription: String? {
            switch self {
            case .invalidStoredValue: return "Saved push-to-talk settings could not be read."
            case .persistenceFailed: return "Push-to-talk settings could not be saved."
            }
        }
    }
    public static func load(from settings: SettingsStore) throws -> PushToTalkSettings {
        guard let value = settings.object(forKey: settingsKey) else { return .init() }
        guard let data = value as? Data, data.count <= maximumStoredBytes else { throw Failure.invalidStoredValue }
        return try JSONDecoder().decode(PushToTalkSettings.self, from: data)
    }
    /// Companion values are prepared by their owner; the profile value cannot be overridden.
    public static func save(_ value: PushToTalkSettings, to settings: SettingsStore, additionalValues: [String: Any?] = [:]) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maximumStoredBytes else { throw Failure.invalidStoredValue }
        var changes = additionalValues
        changes[settingsKey] = data
        guard settings.setValues(changes) else { throw Failure.persistenceFailed }
    }
}
