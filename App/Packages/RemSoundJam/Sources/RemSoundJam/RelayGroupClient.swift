import Foundation

/// Being one person among several on a RemSound server (a relay) - the Mac's copy of the Windows RemSound's
/// `RelayGroupClient` (src/RemSound.Core/RelayGroupClient.cs), which is the reference: same packets, same rules.
///
/// Once connected, it says hello to the relay every 2 seconds with our name, our 8-byte password fingerprint (the relay
/// groups people by it - the same fingerprint every Format packet carries in the clear) and the ids of the people we
/// have ticked. The relay answers with the member list every second. Everything we send to anyone on the relay then goes
/// to the relay itself, group-framed with our client id, and the relay passes it to each member who has ticked us and
/// whom we have ticked. Each member's packets coming back are put into ordinary form and credited to an address of that
/// member's own in 240.0.0.0/5 - reserved, never a real address - so the rest of the app, which keys everyone by address,
/// simply sees one more peer per person.
///
/// Not thread-safe: call everything from one queue (the Mac's `Session` queue). Time is passed in, so the tests drive
/// it without waiting.
public final class RelayGroupClient {
    public static let helloInterval: TimeInterval = 2
    public static let serverPingInterval: TimeInterval = 1
    public static let roundTripsKept = 10
    private static let maximumRoundTrip: TimeInterval = 10
    private static let goodbyeInterval: TimeInterval = 0.1
    private static let goodbyeCopies = 3
    /// The relay sends the member list every second; this long without one and the group is gone.
    public static let groupAliveFor: TimeInterval = 5
    public static let nameBytes = 32
    public static let maxTickedIds = 64
    public static let rosterEntryBytes = JamWire.clientIdSize + nameBytes + 1
    static let rosterEntryBytesWithoutFlags = JamWire.clientIdSize + nameBytes
    /// Member-list flags byte (after the entries), bit 0: we also hold an ordinary pair slot there with a phone or older app.
    public static let rosterFlagV1Paired: UInt8 = 0x01
    /// A member's own flags byte, bit 0: that person has ticked us.
    public static let memberFlagTicksUs: UInt8 = 0x01

    /// One person in our group: their id, their address here, their name, the relay they are behind, and whether they
    /// have ticked us (sound flows only when both have).
    public struct Member: Equatable {
        public let id: UUID
        public let address: JamEndpoint
        public let name: String
        public let relay: JamEndpoint
        public let ticksUs: Bool
    }

    /// What `handleInbound` made of an arriving packet.
    public enum Inbound: Equatable {
        /// Not a group packet: handle it exactly as before.
        case notGroup
        /// Relay bookkeeping (the member list, "the relay is full", the server's metronome): nothing more to do.
        case consumed
        /// A group member's packet, now in ordinary form, and the member's own address to credit it to.
        case delivered(packet: [UInt8], from: JamEndpoint)
    }

    public let clientId: UUID
    /// Our echo uses an ordinary member address but never becomes a peer-list entry.
    public let ownMemberAddress: JamEndpoint
    public private(set) var selfMonitoring = false
    private let clientIdBytes: [UInt8]
    private let pingClock: () -> Int64
    /// Sends one datagram straight to the socket. Our own packets are already framed and must not be routed again.
    public var send: (([UInt8], JamEndpoint) -> Void)?
    /// Group events for the log (joined, somebody arrived or left, the relay is full).
    public var log: ((String) -> Void)?
    /// The groups or their members changed.
    public var changed: (() -> Void)?
    /// A message for the server's metronome from the relay we are in a group on: its body (after the 28-byte header).
    public var timingReceived: (([UInt8], JamEndpoint) -> Void)?

    private final class RelayState {
        let endpoint: JamEndpoint
        var lastRoster: TimeInterval = -.infinity
        var lastHello: TimeInterval = -.infinity
        var sentHello = false
        var inGroup = false
        var inGroupSince: TimeInterval?
        var serverInfo: ServerInfo?
        var roundTrips: [Double] = []
        var nextPing: TimeInterval = -.infinity
        var pendingPings: [Int64] = []
        func forgetStatus() {
            inGroupSince = nil
            serverInfo = nil
            roundTrips.removeAll(keepingCapacity: true)
            pendingPings.removeAll(keepingCapacity: true)
            nextPing = -.infinity
        }
        var v1Paired = false
        var members: [UUID: MemberState] = [:]
        init(_ endpoint: JamEndpoint) { self.endpoint = endpoint }
    }

    private final class MemberState {
        let id: UUID
        let address: JamEndpoint
        let relay: JamEndpoint
        var name = ""
        var listed = false
        var ticksUs = false
        init(id: UUID, address: JamEndpoint, relay: JamEndpoint) {
            self.id = id
            self.address = address
            self.relay = relay
        }
    }

    private var relays: [JamEndpoint: RelayState] = [:]
    private var memberByAddress: [JamEndpoint: MemberState] = [:]
    private struct Departure {
        var nextSend: TimeInterval
        var remaining: Int
    }
    private var departures: [JamEndpoint: Departure] = [:]
    private var departedRelays: Set<JamEndpoint> = []
    private var ticked: Set<UUID> = []
    private var pairPartnerTicked = false
    private var displayName = ""
    private var groupTag: [UInt8]?
    private var timingSequence: UInt32 = 0
    private var now: TimeInterval = 0
    public private(set) var members: [Member] = []

    public init(clientId: UUID, pingClock: @escaping () -> Int64 = MetronomeClock.nowUs) {
        self.clientId = clientId
        self.pingClock = pingClock
        clientIdBytes = JamWire.bytes(of: clientId)
        let value = Self.memberHash(clientId)
        ownMemberAddress = Self.memberEndpoint(value)
    }

    // MARK: who we are and who we talk to

    /// Our name as others see it, and our password fingerprint (nil: no password, so no group to join).
    public func setIdentity(name: String, fingerprint: [UInt8]?) {
        let tag = fingerprint?.count == JamWire.fingerprintSize ? fingerprint : nil
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let changed = trimmed != displayName || tag != groupTag
        displayName = trimmed
        groupTag = tag
        if changed { for r in relays.values { r.lastHello = -.infinity } }
    }

    /// Go to a relay: from now on we say hello to it and its people fill the list. Going to another leaves the first.
    public func connect(_ relay: JamEndpoint) {
        if connectedRelay != relay { setSelfMonitoring(false) }
        let leaving = relays.keys.filter { $0 != relay }
        for r in leaving { leaveRelay(r) }
        // A fresh connection owns this endpoint; no goodbye from its old visit may follow the new hello.
        departures[relay] = nil
        departedRelays.remove(relay)
        if relays[relay] == nil {
            relays[relay] = RelayState(relay)
            log?("connecting to the relay at \(relay) as \(clientId.uuidString.prefix(8).lowercased())")
        }
        publish()
    }

    /// Leave the relay: say goodbye so the others see us go at once, and empty the list.
    public func disconnect() {
        setSelfMonitoring(false)
        let leaving = Array(relays.keys)
        for r in leaving { leaveRelay(r) }
        ticked = []
        pairPartnerTicked = false
        if !leaving.isEmpty { log?("left the relay") }
        publish()
    }

    /// The people we have ticked, by id, and whether the phone or older app paired with us there is ticked. They go to the
    /// relay in every hello: it passes sound between two people only when each has ticked the other.
    public func setTicked(_ ids: Set<UUID>, pairPartner: Bool = false) {
        guard ids != ticked || pairPartner != pairPartnerTicked else { return }
        ticked = ids
        pairPartnerTicked = pairPartner
        for r in relays.values { r.lastHello = -.infinity }   // tell the relay at once
    }

    public func setSelfMonitoring(_ on: Bool) {
        guard selfMonitoring != on else { return }
        selfMonitoring = on
        for r in relays.values { r.lastHello = -.infinity }
    }

    // MARK: what the rest of the app asks

    /// The relay we are connected to, or nil.
    public var connectedRelay: JamEndpoint? { relays.keys.first }

    public func isInGroup(_ relay: JamEndpoint) -> Bool { relays[relay]?.inGroup == true }

    /// Counts and our own audio-arrival telemetry, never names from another group.
    public var latestServerInfo: ServerInfo? { connectedRelay.flatMap { relays[$0]?.serverInfo } }
    public var inGroupSince: TimeInterval? { connectedRelay.flatMap { relays[$0]?.inGroupSince } }
    /// Median of the last ten valid replies, in milliseconds; nil until the server answers.
    public var serverRoundTripMs: Double? {
        guard let endpoint = connectedRelay, let state = relays[endpoint], !state.roundTrips.isEmpty else { return nil }
        let sorted = state.roundTrips.sorted(), middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// True while the member list says we also hold an ordinary pair slot there with a phone or an older app.
    public func isV1Paired(_ relay: JamEndpoint) -> Bool { relays[relay].map { $0.inGroup && $0.v1Paired } ?? false }

    /// The relay behind a member's address, or nil when the address is not a group member's.
    public func relayOf(_ address: JamEndpoint) -> JamEndpoint? { memberByAddress[address]?.relay }

    /// Whether a packet for `destination` goes through a relay group rather than straight to it.
    public func routes(_ destination: JamEndpoint) -> Bool {
        departedRelays.contains(destination) || memberByAddress[destination] != nil
            || JamWire.isMemberAddress(destination.address) || isInGroup(destination)
    }

    /// Whether everyone the relay passes our sound to - each member there who has ticked us and whom we have ticked -
    /// passes `test`, and there is at least one. (Jamulus-style Opus goes through a server only then.)
    public func everyReceiver(on relay: JamEndpoint, _ test: (JamEndpoint) -> Bool) -> Bool {
        var any = selfMonitoring && connectedRelay == relay
        if any && !test(ownMemberAddress) { return false }
        for m in members where m.ticksUs && m.relay == relay && ticked.contains(m.id) {
            if !test(m.address) { return false }
            any = true
        }
        return any
    }

    /// Where sound for the ticked peers goes: somebody on a relay is reached AT the relay, and one copy covers everyone
    /// there. The app's own rule (MainForm.SendTargets on Windows).
    public func sendTargets(for tickedPeers: [JamEndpoint], pairPartnerTicked: Bool = false) -> [JamEndpoint] {
        var result: [JamEndpoint] = []
        var seen = Set<JamEndpoint>()
        for peer in tickedPeers {
            let target = relayOf(peer) ?? peer
            if seen.insert(target).inserted { result.append(target) }
        }
        if pairPartnerTicked || selfMonitoring, let relay = connectedRelay, seen.insert(relay).inserted { result.append(relay) }
        return result
    }

    // MARK: the clock

    /// Call often (the Mac's session tick): hellos every 2 s, and a relay that stopped sending member lists is left.
    public func tick(now: TimeInterval) {
        self.now = now
        var hellos: [JamEndpoint] = []
        var changed = false
        for relay in relays.values {
            if groupTag != nil && now - relay.lastHello >= Self.helloInterval {
                relay.lastHello = now
                hellos.append(relay.endpoint)
            }
            if relay.inGroup && now - relay.lastRoster > Self.groupAliveFor {
                relay.inGroup = false
                relay.forgetStatus()
                relay.v1Paired = false
                changed = true
                log?("no member list from \(relay.endpoint) for \(Int(Self.groupAliveFor)) s: not in its group any more")
                for gone in relay.members.values {
                    log?("\(Self.describe(gone.name)) is no longer listed on \(relay.endpoint): its member lists have stopped")
                    memberByAddress[gone.address] = nil
                }
                relay.members = [:]
            }
        }
        for relay in hellos {
            if let send {
                relays[relay]?.sentHello = true
                send(buildHello(), relay)
            }
        }
        for relay in relays.values where relay.inGroup && now >= relay.nextPing {
            guard let send else { continue }
            let stamp = pingClock()
            relay.pendingPings.removeAll {
                let age = stamp.subtractingReportingOverflow($0)
                return age.overflow || Double(age.partialValue) / 1_000_000 >= Self.maximumRoundTrip
            }
            if relay.pendingPings.count == Self.roundTripsKept { relay.pendingPings.removeFirst() }
            relay.pendingPings.append(stamp)
            relay.nextPing = now + Self.serverPingInterval
            var packet = JamWire.header(JamWire.Kind.serverPing.rawValue, version: JamWire.groupVersion)
            packet.append(contentsOf: clientIdBytes)
            packet.appendLE(stamp)
            send(packet, relay.endpoint)
        }
        serviceDepartures()
        if changed { publish() }
    }

    /// Finish only the outstanding goodbye copies before the owner closes its socket. The owner supplies a
    /// synchronous wait on its worker, never an audio callback. At most two 100 ms intervals remain after leaving.
    /// This advances the private departure clock without sending hellos or restarting any group.
    public func finishDepartures(wait: (TimeInterval) -> Void) {
        while let next = departures.values.map(\.nextSend).min() {
            let delay = max(0, next - now)
            if delay > 0 { wait(delay) }
            now = max(now, next)
            serviceDepartures()
        }
    }

    private func serviceDepartures() {
        for endpoint in Array(departures.keys) {
            guard var departure = departures[endpoint], now >= departure.nextSend else { continue }
            guard relays[endpoint] == nil else { departures[endpoint] = nil; continue }
            departure.remaining -= 1
            departure.nextSend = now + Self.goodbyeInterval
            departures[endpoint] = departure.remaining > 0 ? departure : nil
            sendBye(endpoint)
        }
    }

    // MARK: inbound

    /// A packet arrived on the audio socket. A group packet from our relay is put into ordinary form and credited to the
    /// member who sent it; the relay's own bookkeeping is taken here.
    public func handleInbound(_ packet: [UInt8], from remote: JamEndpoint, now: TimeInterval) -> Inbound {
        self.now = now
        guard packet.count >= JamWire.groupHeaderSize, packet[4] == JamWire.groupVersion, JamWire.hasHeader(packet),
            let relay = relays[remote]
        else { return .notGroup }
        let type = packet[5]
        switch type {
        case JamWire.Kind.roster.rawValue:
            readRoster(from: relay, payload: Array(packet[JamWire.groupHeaderSize...]))
            return .consumed
        case JamWire.Kind.full.rawValue:
            let full = packet.count >= JamWire.groupHeaderSize + 2
                ? " (\(packet[JamWire.groupHeaderSize]) of \(packet[JamWire.groupHeaderSize + 1]))" : ""
            log?("\(remote) is full\(full): this device cannot join its group")
            return .consumed
        case JamWire.Kind.hello.rawValue, JamWire.Kind.bye.rawValue:
            return .consumed
        case JamWire.Kind.serverInfo.rawValue:
            if let info = Self.readServerInfo(Array(packet[JamWire.groupHeaderSize...]), receivedAt: now) {
                if relay.serverInfo == nil {
                    log?("the server at \(remote) says: \(info.version), \(info.people) on it in \(info.groups) group(s), \(info.placesFree) places free")
                }
                relay.serverInfo = info
            }
            return .consumed
        case JamWire.Kind.serverPing.rawValue:
            guard packet.count >= JamWire.groupHeaderSize + 8,
                  packet[JamWire.headerSize..<JamWire.groupHeaderSize].elementsEqual(clientIdBytes) else { return .consumed }
            let stamp = packet.readLE(Int64.self, at: JamWire.groupHeaderSize)
            let age = pingClock().subtractingReportingOverflow(stamp)
            let elapsed = Double(age.partialValue) / 1_000_000
            // Issued echoes only: an old visit, duplicate or invented timestamp cannot skew the median.
            if !age.overflow && elapsed >= 0 && elapsed < Self.maximumRoundTrip,
               let index = relay.pendingPings.firstIndex(of: stamp) {
                relay.pendingPings.remove(at: index)
                if relay.roundTrips.count == Self.roundTripsKept { relay.roundTrips.removeFirst() }
                relay.roundTrips.append(elapsed * 1000)
            }
            return .consumed
        case JamWire.Kind.timing.rawValue:
            timingReceived?(Array(packet[JamWire.groupHeaderSize...]), remote)
            return .consumed
        default:
            break
        }
        let idBytes = packet[JamWire.headerSize..<JamWire.groupHeaderSize]
        if idBytes.elementsEqual(clientIdBytes) {
            guard selfMonitoring, relay.inGroup, type == JamWire.Kind.audio.rawValue || type == JamWire.Kind.format.rawValue
            else { return .consumed }
            var ordinary = Array(packet[0..<JamWire.headerSize])
            ordinary[4] = JamWire.version
            ordinary.append(contentsOf: packet[JamWire.groupHeaderSize...])
            return .delivered(packet: ordinary, from: ownMemberAddress)
        }
        let id = JamWire.uuid(from: idBytes)
        var member = relay.members[id]
        if member == nil {
            let created = MemberState(id: id, address: address(for: id, relay: remote), relay: remote)
            relay.members[id] = created
            memberByAddress[created.address] = created
            member = created
            publish()
        }
        var ordinary = Array(packet[0..<JamWire.headerSize])
        ordinary[4] = JamWire.version
        ordinary.append(contentsOf: packet[JamWire.groupHeaderSize...])
        return .delivered(packet: ordinary, from: member!.address)
    }

    private func readRoster(from relay: RelayState, payload: [UInt8]) {
        guard let count = payload.first.map(Int.init) else { return }
        // A relay from before it said who had ticked you sends entries a byte shorter: read either.
        var entryBytes = Self.rosterEntryBytes
        if count > 0 && payload.count < 1 + count * Self.rosterEntryBytes { entryBytes = Self.rosterEntryBytesWithoutFlags }
        guard payload.count >= 1 + count * entryBytes else { return }
        let flags = payload.count > 1 + count * entryBytes ? payload[1 + count * entryBytes] : 0
        var listed: [UUID: (name: String, ticksUs: Bool)] = [:]
        for i in 0..<count {
            let at = 1 + i * entryBytes
            let idBytes = payload[at..<(at + JamWire.clientIdSize)]
            if idBytes.elementsEqual(clientIdBytes) { continue }
            let ticksUs = entryBytes == Self.rosterEntryBytes && (payload[at + entryBytes - 1] & Self.memberFlagTicksUs) != 0
            let nameField = payload[(at + JamWire.clientIdSize)..<(at + JamWire.clientIdSize + Self.nameBytes)]
            listed[JamWire.uuid(from: idBytes)] = (Self.decodeName(nameField), ticksUs)
        }

        relay.lastRoster = now
        let paired = (flags & Self.rosterFlagV1Paired) != 0
        var changed = !relay.inGroup || relay.v1Paired != paired
        if !relay.inGroup { log?("in a group on \(relay.endpoint) with \(listed.count) other\(listed.count == 1 ? "" : "s")") }
        if relay.v1Paired != paired {
            log?(paired ? "a phone or older app on \(relay.endpoint) is paired with us"
                        : "no longer paired with a phone or older app on \(relay.endpoint)")
        }
        if !relay.inGroup { relay.inGroupSince = now }
        relay.inGroup = true
        relay.v1Paired = paired
        for (id, seen) in listed {
            let member: MemberState
            if let known = relay.members[id] { member = known } else {
                member = MemberState(id: id, address: address(for: id, relay: relay.endpoint), relay: relay.endpoint)
                relay.members[id] = member
                memberByAddress[member.address] = member
            }
            if !member.listed || member.name != seen.name {
                log?(!member.listed
                    ? "\(Self.describe(seen.name)) joined the group on \(relay.endpoint) (as \(member.address.address))"
                    : "\(Self.describe(member.name)) on \(relay.endpoint) is now called \(Self.describe(seen.name))")
                member.listed = true
                member.name = seen.name
                changed = true
            }
            if member.ticksUs != seen.ticksUs {
                log?(seen.ticksUs ? "\(Self.describe(member.name)) has ticked us" : "\(Self.describe(member.name)) has unticked us")
                member.ticksUs = seen.ticksUs
                changed = true
            }
        }
        for gone in relay.members.values where listed[gone.id] == nil {
            log?("\(Self.describe(gone.name)) left the group on \(relay.endpoint)")
            relay.members[gone.id] = nil
            memberByAddress[gone.address] = nil
            changed = true
        }
        if changed { publish() }
    }

    // MARK: outbound

    /// Send `packet` for `destination` through the relay group when it belongs there, and say so. False: send it exactly
    /// as it always has been sent. A packet for one member goes to their relay, group-framed, and so to the whole group
    /// (a pong, a remote-volume command: anyone it was not meant for ignores it). An address check goes back as it came.
    @discardableResult
    public func route(_ packet: [UInt8], to destination: JamEndpoint) -> Bool {
        if departedRelays.contains(destination) { return true }
        if let member = memberByAddress[destination] {
            if isInGroup(member.relay) { sendWrapped(packet, to: member.relay) }
            return true
        }
        if JamWire.isMemberAddress(destination.address) { return true }   // a member we no longer know: never on the wire
        guard let relay = relays[destination], relay.inGroup, packet.count >= JamWire.headerSize else { return false }
        let type = packet[5]
        if type == JamWire.Kind.addressCheck.rawValue { return false }
        sendWrapped(packet, to: destination)
        // Heartbeats also go in ordinary form: they claim the pair slot beside a phone that is waiting for one. The rest
        // goes in ordinary form only while such a partner is paired with us and ticked.
        if type == JamWire.Kind.heartbeat.rawValue || (relay.v1Paired && pairPartnerTicked) { send?(packet, destination) }
        return true
    }

    /// A message for the server's metronome, to the relay we are in a group on. False when we are in no group.
    @discardableResult
    public func sendTiming(_ body: [UInt8]) -> Bool {
        guard let relay = connectedRelay, isInGroup(relay), let send else { return false }
        timingSequence &+= 1
        var packet = JamWire.header(JamWire.Kind.timing.rawValue, stream: 0, sequence: timingSequence, version: JamWire.groupVersion)
        packet.append(contentsOf: clientIdBytes)
        packet.append(contentsOf: body)
        send(packet, relay)
        return true
    }

    private func sendWrapped(_ packet: [UInt8], to relay: JamEndpoint) {
        guard packet.count >= JamWire.headerSize else { return }
        var framed = Array(packet[0..<JamWire.headerSize])
        framed[4] = JamWire.groupVersion
        framed.append(contentsOf: clientIdBytes)
        framed.append(contentsOf: packet[JamWire.headerSize...])
        send?(framed, relay)
    }

    /// Our hello: name, the group tag (our password fingerprint), then the people we have ticked - a count and that many
    /// ids. Somebody ticked who is on the relay now goes first, so the 64-id cap never leaves out somebody here.
    func buildHello() -> [UInt8] {
        let present = Set(members.map(\.id))
        var ids = ticked.filter { $0 != clientId }.sorted { present.contains($0) && !present.contains($1) }
        if selfMonitoring { ids.insert(clientId, at: 0) }
        ids = Array(ids.prefix(Self.maxTickedIds))
        var packet = JamWire.header(JamWire.Kind.hello.rawValue, version: JamWire.groupVersion)
        packet.append(contentsOf: clientIdBytes)
        packet.append(contentsOf: Self.encodeName(displayName))
        packet.append(contentsOf: groupTag ?? [UInt8](repeating: 0, count: JamWire.fingerprintSize))
        packet.append(UInt8(ids.count))
        for id in ids { packet.append(contentsOf: JamWire.bytes(of: id)) }
        return packet
    }

    private func sendBye(_ relay: JamEndpoint) {
        var packet = JamWire.header(JamWire.Kind.bye.rawValue, version: JamWire.groupVersion)
        packet.append(contentsOf: clientIdBytes)
        send?(packet, relay)
    }

    // MARK: bookkeeping

    private func leaveRelay(_ endpoint: JamEndpoint) {
        guard let relay = relays[endpoint] else { return }
        let needsGoodbye = relay.sentHello || relay.inGroup
        forgetRelay(endpoint)
        departedRelays.insert(endpoint)
        guard needsGoodbye else { return }
        departures[endpoint] = Departure(nextSend: now + Self.goodbyeInterval, remaining: Self.goodbyeCopies - 1)
        sendBye(endpoint)
    }

    private func forgetRelay(_ endpoint: JamEndpoint) {
        guard let relay = relays.removeValue(forKey: endpoint) else { return }
        for m in relay.members.values { memberByAddress[m.address] = nil }
    }

    /// A member's address: 240.0.0.0/5 plus an FNV-1a hash of their client id, so the same person always gets the same
    /// address (their volume and pan, kept by address, come back with them). Two ids that hash alike: the next free one.
    private func address(for id: UUID, relay: JamEndpoint) -> JamEndpoint {
        if id == clientId { return ownMemberAddress }
        var value = Self.memberHash(id)
        while true {
            let candidate = Self.memberEndpoint(value)
            if candidate == ownMemberAddress {
                value = 0xF000_0000 | ((value &+ 1) & 0x07FF_FFFF)
                continue
            }
            if let holder = memberByAddress[candidate], !(holder.id == id && holder.relay == relay) {
                value = 0xF000_0000 | ((value &+ 1) & 0x07FF_FFFF)
                continue
            }
            return candidate
        }
    }

    private static func memberHash(_ id: UUID) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for b in JamWire.bytes(of: id) { hash = (hash ^ UInt32(b)) &* 16_777_619 }
        return 0xF000_0000 | (hash & 0x07FF_FFFF)
    }
    private static func memberEndpoint(_ value: UInt32) -> JamEndpoint {
        JamEndpoint("\(value >> 24).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)", JamWire.defaultPort)
    }

    private func publish() {
        members = memberByAddress.values
            .map { Member(id: $0.id, address: $0.address, name: $0.name, relay: $0.relay, ticksUs: $0.ticksUs) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        changed?()
    }

    private static func describe(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).isEmpty ? "someone not yet named" : "\"\(name)\""
    }

    /// The relay's name field: UTF-8, cut to 32 bytes on a character boundary, zero-padded.
    static func encodeName(_ name: String) -> [UInt8] {
        var text = name
        while text.utf8.count > nameBytes { text.removeLast() }
        var field = Array(text.utf8)
        field.append(contentsOf: [UInt8](repeating: 0, count: nameBytes - field.count))
        return field
    }

    static func decodeName(_ field: ArraySlice<UInt8>) -> String {
        let end = field.firstIndex(of: 0) ?? field.endIndex
        return String(decoding: field[field.startIndex..<end], as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}
