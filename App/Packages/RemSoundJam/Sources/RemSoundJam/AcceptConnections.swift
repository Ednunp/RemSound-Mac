import Foundation

/// What happens when somebody else ticks you: Windows' "Accept connections from other peers" (MainForm.AcceptConnections:
/// Ed 2026-09-20; tick proofs 2026-09-25; never on another password 2026-09-29). Kept machine-wide, as on Windows.
public enum AcceptConnections: String, CaseIterable, Sendable {
    /// A question with their name and where they are, answered once a run. The default.
    case ask
    /// Tick them back the moment they tick you.
    case automatic
    /// Nothing happens until you tick them yourself: how RemSound always worked.
    case manual

    /// The words of the Preferences choice, as Windows says them.
    public var title: String {
        switch self {
        case .ask: return "Ask me each time"
        case .automatic: return "Automatically - connect when someone ticks me"
        case .manual: return "Manual - I tick them myself"
        }
    }

    public static let `default` = AcceptConnections.ask
    public static let settingsKey = "RemSoundAcceptConnections"
}

/// The decisions behind accept connections, kept apart from the network so they can be tested on their own. One per
/// session, used only on its queue. The session tells it what arrived; it says what to do and what to log.
public struct AcceptPolicy {
    public enum Action: Equatable {
        /// Nothing to do.
        case nothing
        /// Tick them now; `description` is how to name them ("Studio at 192.168.1.20").
        case accept(description: String)
        /// Ask the person; on a yes, tick them. `key` is what the answer is remembered under.
        case ask(key: String, question: String, description: String)
    }
    public struct Outcome: Equatable {
        public var action: Action
        public var log: [String]
    }

    public var mode = AcceptConnections.default
    /// Addresses and server members already asked about, so one answer lasts the run. A "no" is remembered as a "yes"
    /// is: the point of asking once is not asking again.
    public private(set) var asked = Set<String>()
    /// People the person has unticked themselves this run. Without this, unticking somebody who still has you ticked puts
    /// them straight back (Ed, 2026-09-21). It holds until the person ticks them again, or the next run.
    public private(set) var refusedByUser = Set<String>()
    /// One question at a time: while one is open the rest wait for the next time round.
    public private(set) var promptOpen = false
    /// When each address last showed another password. It counts for two minutes, so somebody who changes their
    /// password is accepted soon after.
    private var differentPasswordSeen: [String: TimeInterval] = [:]
    public static let differentPasswordMemory: TimeInterval = 120
    /// Things already said in the log, so a repeating sender doesn't fill it.
    private var said = Set<String>()
    /// At most one look at an unticked sender's packet every two seconds: a peer sends a proof every five, and a flood
    /// costs a lookup, not a decryption each.
    private var lastLook: [String: TimeInterval] = [:]

    public init() {}

    public static func peerKey(_ address: String) -> String { "peer:\(address)" }
    public static func memberKey(_ id: UUID) -> String { "member:\(id.uuidString)" }

    /// Whether to look at this unticked sender's packet at all now.
    public mutating func mayLook(_ address: String, now: TimeInterval) -> Bool {
        guard mode != .manual else { return false }
        if let last = lastLook[address], now >= last, now - last < 2 { return false }
        if lastLook.count >= 1024 { lastLook.removeAll() }
        lastLook[address] = now
        return true
    }

    /// Their proof wouldn't open with our password, or their stream carries another password's fingerprint.
    public mutating func noteDifferentPassword(_ address: String, now: TimeInterval) -> [String] {
        if differentPasswordSeen.count >= 256 { differentPasswordSeen.removeAll() }
        differentPasswordSeen[address] = now
        guard said.insert("password:\(address)").inserted else { return [] }
        return ["accept connections: \(address) has ticked us but uses a different password - not offered or accepted"]
    }

    /// The person's own tick or untick, from the peer list.
    public mutating func userChose(_ key: String, selected: Bool) {
        if selected { refusedByUser.remove(key) } else { refusedByUser.insert(key) }
    }

    /// Somebody at `address` has ticked us (`how` says how we know). Not ticked already, not unticked by the person, not
    /// on another password, not a server, asked about once a run - then tick them back, or ask.
    public mutating func considerPeer(address: String, name: String?, how: String, isSelected: Bool, isServer: Bool,
                                      now: TimeInterval) -> Outcome {
        guard mode != .manual, !isSelected else { return .init(action: .nothing, log: []) }
        let key = Self.peerKey(address)
        guard !refusedByUser.contains(key) else { return .init(action: .nothing, log: []) }
        let shown = name.flatMap { $0.isEmpty || $0 == address ? nil : $0 }
        let description = shown.map { "\($0) at \(address)" } ?? address
        if let seen = differentPasswordSeen[address], now >= seen, now - seen < Self.differentPasswordMemory {
            return .init(action: .nothing, log: said.insert("password-again:\(address)").inserted
                ? ["accept connections: \(description) \(how), but uses a different password - not offered or accepted"] : [])
        }
        // A server's address is not a person: the people behind one arrive in its list with names of their own.
        if isServer {
            return .init(action: .nothing, log: said.insert("server:\(address)").inserted
                ? ["accept connections: \(address) \(how), but it's a server - not accepted as a peer"] : [])
        }
        guard asked.insert(key).inserted else { return .init(action: .nothing, log: []) }
        let line = "accept connections: \(description) \(how) and is not ticked (mode=\(mode.rawValue))"
        if mode == .automatic { return .init(action: .accept(description: description), log: [line]) }
        return .init(action: .ask(key: key, question: "\(description) would like to connect to you.", description: description),
                     log: [line])
    }

    /// Somebody on the server has ticked us and we haven't ticked them: the server's list says so outright. Everybody there
    /// is on our password - the server groups by it - so there is nothing more to check than that we haven't answered.
    public mutating func considerMember(id: UUID, name: String, isSelected: Bool) -> Outcome {
        guard mode != .manual, !isSelected else { return .init(action: .nothing, log: []) }
        let key = Self.memberKey(id)
        guard !refusedByUser.contains(key), asked.insert(key).inserted else { return .init(action: .nothing, log: []) }
        let who = name.isEmpty ? "Someone" : name
        let line = "accept connections: \(who) has ticked us on the server (mode=\(mode.rawValue))"
        if mode == .automatic { return .init(action: .accept(description: who), log: [line]) }
        return .init(action: .ask(key: key, question: "\(who) on the server would like to connect to you.", description: who),
                     log: [line])
    }

    /// Whether a question can be put now. While one is open the rest wait: forgetting that we asked is what brings the
    /// question back next time round.
    public mutating func beginQuestion(_ key: String) -> Bool {
        if promptOpen { asked.remove(key); return false }
        promptOpen = true
        return true
    }

    public mutating func endQuestion() { promptOpen = false }
}
