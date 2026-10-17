import Foundation
import RemSoundRuntime

/// Machine-wide key choice; profile PTT settings never contain this binding.
enum PushToTalkKeyPreferences {
    static let settingsKey = "pushToTalkHotkey"
    static let maximumStoredBytes = 4_096
    private struct Stored: Codable {
        let version: Int
        let binding: HotkeyDescriptor?
    }
    private enum Failure: LocalizedError {
        case invalidStoredValue, invalidBinding, persistenceFailed
        var errorDescription: String? {
            switch self {
            case .invalidStoredValue: return "The saved push-to-talk key could not be read."
            case .invalidBinding: return "This key cannot be used for push-to-talk."
            case .persistenceFailed: return "The push-to-talk key could not be saved."
            }
        }
    }
    static func load(from settings: SettingsStore) throws -> HotkeyDescriptor? {
        guard let value = settings.object(forKey: settingsKey) else { return nil }
        guard let data = value as? Data, data.count <= maximumStoredBytes,
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.version == 1,
              stored.binding == nil || stored.binding?.isValidForPushToTalk == true else {
            throw Failure.invalidStoredValue
        }
        return stored.binding
    }
    static func encoded(_ binding: HotkeyDescriptor?) throws -> Data {
        guard binding == nil || binding?.isValidForPushToTalk == true else { throw Failure.invalidBinding }
        let data = try JSONEncoder().encode(Stored(version: 1, binding: binding))
        guard data.count <= maximumStoredBytes else { throw Failure.invalidBinding }
        return data
    }
    static func save(_ binding: HotkeyDescriptor?, to settings: SettingsStore) throws {
        let data = try encoded(binding)
        settings.set(data, forKey: settingsKey)
        guard !settings.persistenceFailed else { throw Failure.persistenceFailed }
    }
}
