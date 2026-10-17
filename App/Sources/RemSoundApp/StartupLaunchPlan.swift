import Foundation
import RemSoundCore
import RemSoundRuntime

enum StartupLaunchError: Error, LocalizedError {
    case missingProfile, ambiguousProfile
    var errorDescription:String? {
        switch self {
        case .missingProfile: return "The requested startup profile was not found. Use --list-profiles to inspect available names."
        case .ambiguousProfile: return "The startup profile name is ambiguous. Use its exact name or rename a duplicate profile."
        }
    }
}
struct StartupLaunchPlan {
    let profile:ConnectionProfile?
    let blank:Bool
    let selectedPeers:[String]
    var overridesProfile:Bool { profile != nil || blank }
    let startRequested:Bool
    static func make(_ options:StartupOptions, profiles:() throws -> [ConnectionProfile]) throws -> Self {
        var chosen:ConnectionProfile?
        if let name = options.profileName {
            let all = try profiles(), exact = all.filter { $0.title == name }
            let matches = exact.isEmpty ? all.filter { $0.title.caseInsensitiveCompare(name) == .orderedSame } : exact
            guard !matches.isEmpty else { throw StartupLaunchError.missingProfile }
            guard matches.count == 1 else { throw StartupLaunchError.ambiguousProfile }
            chosen = matches[0]
        }
        var peers = chosen?.selectedPeerAddresses ?? []
        for address in options.connectPeers where !peers.contains(address) { peers.append(address) }
        return Self(profile:chosen,blank:chosen == nil && !options.connectPeers.isEmpty,selectedPeers:peers,
            startRequested:!options.connectPeers.isEmpty || chosen?.reconnectOnOpen == true)
    }
}
@MainActor final class StartupRequestOwner {
    private var current:UUID?, closed = false
    func begin() -> UUID { let id = UUID();if !closed { current = id };return id }
    func consume(_ id:UUID) -> Bool {
        guard !closed, current == id else { return false };current = nil;return true
    }
    func invalidate() { current = nil }
    func shutdown() { closed = true;invalidate() }
}
