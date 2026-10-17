import Foundation

/// A server named by its name (Windows MainForm.NameLookups, 2026-09-25 sweep). Kept apart from the network so it can be
/// tested on its own; one per session, used only on its queue.
///
/// A profile that connects at start names its server, and at sign-in the name often cannot be looked up yet - the Wi-Fi
/// is not up, the VPN's names are not ready. The profile's own server is kept and tried again every 30 seconds and
/// whenever the network changes, and saving keeps it as "connect at start". And a server by name that stops answering may
/// simply have moved - a home connection with no fixed address. After 30 seconds of silence, or a network change, the name
/// is looked up again, and a new address is followed.
public struct ServerNameWatch {
    public static let retryInterval: TimeInterval = 30
    public static let movedAfter: TimeInterval = 30

    /// The profile's own server, kept while its name cannot be looked up yet.
    public private(set) var pending: String?
    /// A lookup of the connected server's name is under way.
    public private(set) var recheckRunning = false
    private var nextRetry: TimeInterval = 0
    private var silentSince: TimeInterval?
    private var nextRecheck: TimeInterval = 0

    public init() {}

    /// "host" or "host:port" that is an IPv4 address already: nothing to look up, so it cannot move.
    public static func isAddress(_ entry: String) -> Bool {
        let host = entry.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? entry
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy { $0.isASCII && $0.isNumber } && Int(part)! <= 255
        }
    }

    /// The person chose a server, or disconnected: any wait for the profile's own ends.
    public mutating func userChose() { pending = nil }

    /// The name could not be looked up. The profile's own server (not `userAsked`) is kept and tried again.
    public mutating func notFound(_ entry: String, userAsked: Bool, now: TimeInterval) -> [String] {
        guard !userAsked else { return ["could not resolve \"\(entry)\""] }
        let first = pending?.caseInsensitiveCompare(entry) != .orderedSame
        pending = entry
        nextRetry = now + Self.retryInterval
        return first ? ["could not resolve \"\(entry)\" - trying again every \(Int(Self.retryInterval)) s and when the network changes"] : []
    }

    /// The name was found and the server is being joined.
    public mutating func found(_ entry: String) -> [String] {
        silentSince = nil
        defer { pending = nil }
        return pending == nil ? [] : ["\"\(entry)\" found at last"]
    }

    /// The profile's server to try again now, if one is waiting and it is time (or the network changed).
    public mutating func retryDue(now: TimeInterval, networkChanged: Bool, connected: Bool) -> String? {
        guard let pending, !connected, networkChanged || now >= nextRetry else { return nil }
        nextRetry = now + Self.retryInterval
        return pending
    }

    /// Whether the server we are on is answering, from the same place the status line learns it.
    public mutating func noteAnswering(_ answering: Bool, now: TimeInterval) {
        if answering { silentSince = nil } else if silentSince == nil { silentSince = now }
    }

    /// Whether to look the connected server's name up again now: by name, and silent 30 seconds or the network changed.
    public mutating func recheckDue(entry: String, connected: Bool, now: TimeInterval, networkChanged: Bool) -> Bool {
        guard connected, !recheckRunning, !entry.isEmpty, !Self.isAddress(entry) else { return false }
        let silentLongEnough = silentSince.map { now - $0 >= Self.movedAfter } ?? false
        guard networkChanged || (silentLongEnough && now >= nextRecheck) else { return false }
        nextRecheck = now + Self.movedAfter
        recheckRunning = true
        return true
    }

    /// The look-up's answer. Returns the line to log when the name now says somewhere else, which is to be followed;
    /// nil to stay where we are.
    public mutating func recheckFinished(entry: String, current: String?, found: String?) -> String? {
        recheckRunning = false
        guard let current, let found, found != current else { return nil }
        return "\"\(entry)\" now looks up to \(found), not \(current) - it has moved; following it"
    }

    /// The lookup was abandoned (we left the server, or stopped).
    public mutating func recheckAbandoned() { recheckRunning = false }

    /// Saving a profile: connect at start when connected, or when still waiting for this same server's name - that is
    /// the profile's choice, not a change of mind. Saved as "not connected", the next start did not even try.
    public func connectOnStart(server: String, connected: Bool) -> Bool {
        guard !server.isEmpty else { return false }
        return connected || pending?.caseInsensitiveCompare(server) == .orderedSame
    }
}
