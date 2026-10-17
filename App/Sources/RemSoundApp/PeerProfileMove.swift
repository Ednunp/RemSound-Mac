import Foundation
import RemSoundCore
import RemSoundRuntime

/// The connection owner's move handler keeps explicit destination choices and retains the original entries.
enum PeerProfileMove {
    static func apply(from old: String, to new: String, mixes: inout [String: PeerMix],
                      aliases: inout [String: String], settings: SettingsStore) {
        if mixes[new] == nil { mixes[new] = mixes[old] }
        if aliases[new] == nil { aliases[new] = aliases[old] }
        settings.set(aliases, forKey: "peerAliases")
        if let data = try? JSONEncoder().encode(mixes) { settings.set(data, forKey: "peerMixes") }
    }
}

enum PeerAddressLockChoice {
    static func save(_ locked: Bool, settings: SettingsStore) -> Bool {
        settings.set(locked, forKey: "lockPeerAddresses")
        return settings.bool(forKey: "lockPeerAddresses") == locked
    }
}
