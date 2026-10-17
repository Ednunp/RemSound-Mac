import Foundation

/// The Mac's metronome - the Windows RemSound's MetronomeEngine as it works through a server (the reference:
/// src/RemSound.Core/MetronomeEngine.cs, and PLAN-metronome-server-2026-09-29.md in the Windows tree).
///
/// Ed's rules (2026-09-29): the shared metronome is the SERVER's. Through a server, whoever leads it controls it: the
/// server keeps the beat and sends every computer its own beat grid, early by exactly how long that computer's sound takes
/// to reach the server, so every note played on its click reaches the server on the beat and everybody hears the band
/// together. Anyone can ask to lead, as before: the others are asked (and a leader is asked before handing over). With no
/// server there is no shared metronome - your own still clicks for you alone, and the app says nobody else will hear it.
///
/// Asking and answering go as the sealed metronome messages (`MetronomeMessage`), between people on the server; the
/// server's own messages (claim, the setting, release, the grids) go through `toServer`. Everything is called from one
/// queue (the Mac's Session queue). `tick()` wants calling every 50-100 ms.
public final class ServerMetronome {
    public enum Role: Equatable, Sendable { case solo, master, follower }
    public enum WhenAsked: Equatable, Sendable { case ask, acceptAutomatically, declineAutomatically }

    public struct Settings: Equatable, Sendable {
        public var bpm: Int = 120
        public var signature = MetronomeSignature.default
        public var whenAsked = WhenAsked.ask
        public var volume: Float = 0.7
        public init() {}
        public var clampedBpm: Int { min(max(bpm, Int(MetronomeTimeline.minBpm)), Int(MetronomeTimeline.maxBpm)) }
    }

    public static let offerEveryUs: Int64 = 2_000_000
    public static let offerForUs: Int64 = 10_000_000
    public static let followerTimeoutUs: Int64 = 5_000_000
    public static let serverGridStaleUs: Int64 = 3_000_000
    public static let serverClaimGiveUpUs: Int64 = 6_000_000
    static let serverRepeatUs: Int64 = 1_000_000

    // MARK: what the app provides

    /// Seal and send a message to a peer (through the server when they are on it: the relay routes it).
    public var sendMessage: ((MetronomeMessage, JamEndpoint) -> Void)?
    /// A message for the server's metronome (claim, setting, release): `RelayGroupClient.sendTiming`.
    public var toServer: (([UInt8]) -> Void)?
    /// Who is on the server with us, to offer to: each member's address here and name.
    public var peers: (() -> [(JamEndpoint, String)])?
    /// Connected through a server, in its group.
    public var onServerNow: (() -> Bool)?
    /// A server member's name by client id, for the words.
    public var memberName: ((UUID) -> String?)?
    /// Ask the person whether to follow (or, leading, whether to hand over): the name, and call the answer back.
    public var askAboutOffer: ((_ name: String, _ whileLeading: Bool, _ answer: @escaping (Bool) -> Void) -> Void)?
    /// Something the person should hear or see (spoken on the Mac).
    public var notice: ((String) -> Void)?
    public var log: ((String) -> Void)?
    /// The role, playing, the leader or the words changed: refresh the menu.
    public var changed: (() -> Void)?

    // MARK: state

    public private(set) var role = Role.solo
    public private(set) var masterName = ""
    public private(set) var muted = false
    public private(set) var settings = Settings()
    private let clock: () -> Int64
    private var own = MetronomeTimeline.stopped()
    private var ownPrevious: MetronomeTimeline?
    private var masterSession: UInt64 = 0
    private var followSession: UInt64 = 0
    private var masterEndpoint: JamEndpoint?
    private var myName = ""
    private struct Offered { var name: String; var firstUs: Int64; var lastUs: Int64; var answered = false; var accepted = false; var noted = false }
    private var offered: [JamEndpoint: Offered] = [:]
    private var followers: [JamEndpoint: String] = [:]
    private var grid: ServerGrid?
    private var gridPrevious: MetronomeTimeline?
    private var lastGridUs: Int64 = .min / 2
    private var claimSinceUs: Int64 = 0
    private var nextServerSendUs: Int64 = 0
    private var followingSinceUs: Int64 = 0

    public init(clock: @escaping () -> Int64 = MetronomeClock.nowUs) {
        self.clock = clock
    }

    public var onServer: Bool { onServerNow?() == true }
    public var followerCount: Int { followers.count }
    /// Playing, as the person hears it: the server's grid when it is the server's metronome, your own otherwise.
    public var playing: Bool { schedule?.current.running == true }

    /// This machine's grid from the server, while it keeps coming.
    public var serverGridNow: ServerGrid? {
        guard let grid, clock() - lastGridUs < Self.serverGridStaleUs else { return nil }
        return grid
    }

    // MARK: settings and your own metronome

    public func configure(_ value: Settings) {
        settings = value
        let changed = own.change(nowUs: clock(), milliBpm: UInt32(value.clampedBpm) * 1000, signature: value.signature)
        if changed != own {
            if own.running { ownPrevious = own }
            own = changed
            if role == .master { sendSetToServer() }
        }
        self.changed?()
    }

    /// Start or stop your own metronome (and, leading, the server's); following, mute or unmute your clicks.
    public func startStop() {
        if role == .follower {
            muted.toggle()
            log?("metronome: \(muted ? "muted" : "unmuted") - \(masterName)'s master metronome plays on")
            changed?()
            return
        }
        if own.running { own = own.stop() } else { own = own.start(nowUs: clock()) }
        ownPrevious = nil
        log?("metronome: \(own.running ? "started, \(own)" : "stopped")\(role == .master ? " for the server" : "")")
        if role == .master { sendSetToServer() }
        changed?()
    }

    // MARK: leading

    /// Be the master metronome: needs a server (it keeps everyone's beat). Asks everyone there to follow, and claims the
    /// server's metronome. False, and nothing changes, with no server.
    @discardableResult
    public func becomeMaster(name: String) -> Bool {
        guard role != .master else { return true }
        guard onServer else {
            log?("metronome: being the master metronome needs a server - not connected to one")
            return false
        }
        if role == .follower { stopFollowing("you became the master metronome", sendLeave: true) }
        role = .master
        masterSession = MetronomeMessage.newSessionId()
        myName = name
        offered = [:]
        followers = [:]
        log?("metronome: you are the master metronome; offering to everyone on the server, and claiming the server's metronome")
        claimSinceUs = 0
        nextServerSendUs = 0
        let now = clock()
        offerToNewPeers(now)
        tickServerMaster(now)
        changed?()
        return true
    }

    /// Stop being the master: followers are let go, the server's metronome is released (and stops).
    public func releaseMaster() {
        guard role == .master else { return }
        for (to, _) in followers { sendMessage?(MetronomeMessage(.release, sessionId: masterSession), to) }
        if onServer { toServer?(ServerMetronomeWire.buildRelease()) }
        log?("metronome: no longer the master metronome; \(followers.count) follower(s) let go")
        masterSession = 0
        offered = [:]
        followers = [:]
        role = .solo
        changed?()
    }

    private func sendSetToServer() {
        guard role == .master, onServer else { return }
        toServer?(ServerMetronomeWire.buildSet(running: own.running, milliBpm: own.milliBpm, beatsPerBar: own.beatsPerBar, beatUnit: own.beatUnit))
    }

    /// Once a second: claim the server's metronome until it is ours, then repeat the setting (in case one was lost).
    /// Refused for 6 s - somebody else leads it and did not hand over - it lets go and says who leads.
    private func tickServerMaster(_ now: Int64) {
        guard now >= nextServerSendUs else { return }
        nextServerSendUs = now + Self.serverRepeatUs
        let g = serverGridNow
        if g?.youLead == true { sendSetToServer(); return }
        toServer?(ServerMetronomeWire.buildClaim())
        sendSetToServer()
        if claimSinceUs == 0 { claimSinceUs = now; return }
        guard now - claimSinceUs >= Self.serverClaimGiveUpUs, let g, g.master != ServerMetronomeWire.nobody else { return }
        let who = memberName?(g.master) ?? "Someone else"
        log?("metronome: the server's metronome stays with \(who) - letting go of being the master metronome")
        notice?("\(who) leads the server's metronome")
        claimSinceUs = 0
        releaseMaster()
    }

    private func offerToNewPeers(_ now: Int64) {
        guard role == .master || masterSession != 0 else { return }
        for (endpoint, name) in peers?() ?? [] {
            if var o = offered[endpoint] {
                guard !o.answered else { continue }
                if now - o.firstUs >= Self.offerForUs {
                    if !o.noted {
                        o.noted = true
                        offered[endpoint] = o
                        log?("metronome: \(o.name) never answered the offer (an older RemSound, a phone, or not there)")
                        notice?("\(o.name) did not answer the metronome offer")
                    }
                    continue
                }
                if now - o.lastUs >= Self.offerEveryUs {
                    o.lastUs = now
                    offered[endpoint] = o
                    sendMessage?(MetronomeMessage(.offer, sessionId: masterSession, masterName: myName), endpoint)
                }
            } else {
                offered[endpoint] = Offered(name: name, firstUs: now, lastUs: now)
                sendMessage?(MetronomeMessage(.offer, sessionId: masterSession, masterName: myName), endpoint)
                log?("metronome: offered to lead \(name)")
            }
        }
    }

    // MARK: following

    /// Stop following: back to your own metronome (stopped). Tell the master unless it is gone.
    public func stopFollowing(_ why: String, sendLeave: Bool) {
        guard role == .follower else { return }
        if sendLeave, let masterEndpoint { sendMessage?(MetronomeMessage(.leave, sessionId: followSession), masterEndpoint) }
        log?("metronome: stopped following \(masterName)'s master metronome - \(why)")
        notice?("Stopped following \(masterName)'s master metronome: \(why).")
        role = .solo
        followSession = 0
        masterEndpoint = nil
        muted = false
        changed?()
    }

    private func follow(_ offer: MetronomeMessage, from: JamEndpoint) {
        if role == .master {
            log?("metronome: handing over to \(offer.masterName)")
            releaseMaster()
        }
        role = .follower
        followSession = offer.sessionId
        masterEndpoint = from
        masterName = offer.masterName
        followingSinceUs = clock()
        muted = false
        sendMessage?(MetronomeMessage(.accept, sessionId: offer.sessionId), from)
        log?("metronome: following \(offer.masterName)'s master metronome\(onServer ? " through the server" : "")")
        changed?()
    }

    /// The answer to an offer the person was asked about.
    public func answerOffer(_ offer: MetronomeMessage, from: JamEndpoint, accept: Bool) {
        if accept { follow(offer, from: from) } else {
            sendMessage?(MetronomeMessage(.decline, sessionId: offer.sessionId), from)
            log?("metronome: said no to following \(offer.masterName)")
        }
    }

    // MARK: arriving

    /// An opened metronome message from a peer (after the seal and the replay guard).
    public func handle(_ m: MetronomeMessage, from: JamEndpoint) {
        switch m.kind {
        case .offer:
            if role == .follower && m.sessionId == followSession { return }   // a repeat of the one we follow
            if role == .master {
                // Somebody asks to take over: the leader is asked; with nobody to ask, no.
                log?("metronome: \(m.masterName) asks to take over as the master metronome")
                guard let askAboutOffer else { answerOffer(m, from: from, accept: false); return }
                askAboutOffer(m.masterName, true) { [weak self] yes in self?.answerOffer(m, from: from, accept: yes) }
                return
            }
            log?("metronome: \(m.masterName) asks to be the master metronome")
            switch settings.whenAsked {
            case .acceptAutomatically: follow(m, from: from)
            case .declineAutomatically: answerOffer(m, from: from, accept: false)
            case .ask:
                guard let askAboutOffer else { answerOffer(m, from: from, accept: false); return }
                askAboutOffer(m.masterName, false) { [weak self] yes in self?.answerOffer(m, from: from, accept: yes) }
            }
        case .accept, .decline:
            guard role == .master, m.sessionId == masterSession, var o = offered[from] else { return }
            o.answered = true
            o.accepted = m.kind == .accept
            offered[from] = o
            if o.accepted {
                followers[from] = o.name
                log?("metronome: \(o.name) accepted - following you (\(followers.count) follower(s))")
                notice?("\(o.name) is following your metronome")
            } else {
                log?("metronome: \(o.name) said no")
                notice?("\(o.name) said no to following your metronome")
            }
            changed?()
        case .leave:
            guard role == .master, let name = followers.removeValue(forKey: from) else { return }
            log?("metronome: \(name) stopped following")
            changed?()
        case .release:
            guard role == .follower, m.sessionId == followSession else { return }
            stopFollowing("\(masterName) let go of the master metronome", sendLeave: false)
        case .state, .syncRequest, .syncReply:
            break   // direct-connection timing: through a server the grid carries the beat
        }
    }

    /// The server's grid for this machine arrived.
    public func onGrid(_ g: ServerGrid) {
        let before = serverGridNow
        let versionChanged = before == nil || before!.timeline.version != g.timeline.version
        if versionChanged {
            gridPrevious = before.map { $0.running && g.running && g.timeline.anchorBeat > $0.timeline.anchorBeat ? $0.timeline : nil } ?? nil
        }
        grid = g
        lastGridUs = clock()
        if versionChanged || before!.measured != g.measured || before!.youLead != g.youLead {
            let who = g.youLead ? ", you lead it" : g.master == ServerMetronomeWire.nobody ? ", nobody leads it"
                : ", \(memberName?(g.master) ?? "someone") leads it"
            log?("metronome: the server's grid - \(g.timeline)\(g.measured ? "" : ", this machine's delay not measured yet")\(who)")
            changed?()
        }
        if g.youLead { claimSinceUs = 0 }
    }

    // MARK: the timer

    public func tick() {
        let now = clock()
        if role == .master {
            if onServer { tickServerMaster(now) } else { releaseMaster() }
            offerToNewPeers(now)
        } else if role == .follower {
            if !onServer { stopFollowing("not on the server any more", sendLeave: false) }
            else if now - lastGridUs > Self.followerTimeoutUs && now - followingSinceUs > Self.followerTimeoutUs {
                stopFollowing("nothing heard from the server's metronome for \(Self.followerTimeoutUs / 1_000_000) seconds", sendLeave: true)
            }
        }
    }

    // MARK: what the outputs play

    /// Through a server, leading or following: this machine's grid from the server, and nothing until it has been measured
    /// (never a beat nobody else shares). Otherwise your own.
    public var schedule: MetronomeSchedule? {
        if onServer && role != .solo {
            guard let g = serverGridNow, g.measured else { return nil }
            return MetronomeSchedule(current: g.timeline, previous: gridPrevious, audible: !(role == .follower && muted))
        }
        guard own.running || ownPrevious?.running == true else { return nil }
        return MetronomeSchedule(current: own, previous: ownPrevious, audible: true)
    }

    /// One line for the menu and the log.
    public func describe() -> String {
        switch role {
        case .follower:
            let g = serverGridNow
            let state = g?.running == true ? "playing \(g!.timeline.bpmText) bpm \(g!.timeline.signature)" : "stopped"
            return "following \(masterName)'s master metronome through the server, \(state)\(muted ? ", muted" : "")"
                + (g?.measured == true ? "" : ", timing this computer")
        case .master:
            return "master metronome through the server for \(followers.count) follower(s), "
                + (own.running ? "playing \(own.bpmText) bpm \(own.signature)" : "stopped")
                + (serverGridNow?.youLead == true ? "" : ", waiting for the server")
        case .solo:
            return own.running ? "playing \(own.bpmText) bpm \(own.signature)" : "stopped"
        }
    }
}
