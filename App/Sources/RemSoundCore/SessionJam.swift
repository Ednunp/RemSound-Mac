import Foundation
import Network
import RemSoundJam

/// What the app shows about the server and the metronome: the Server menu, the Server window and the Metronome menu.
public struct JamView: Equatable {
    /// The server has acknowledged this client's group membership.
    public let connected: Bool
    /// The server as typed, while connected or connecting.
    public let server: String
    /// One line on what the server is doing ("Connecting to …", "On … with 2 others", "Couldn't find …").
    public let serverStatus: String
    /// Multiline telemetry for the Server window, separate from short connection announcements.
    public let serverDetails: String?
    /// The profile's own server, while its name cannot be looked up yet and is being tried again.
    public let pendingServer: String?
    /// While following: the master's name, and the tempo and signature that are theirs (the settings window shows them).
    public let masterName: String?
    public let masterBpm: Int?
    public let masterSignature: MetronomeSignature?
    /// The metronome: its role, whether it plays, and one line saying so.
    public let metronomeRole: ServerMetronome.Role
    public let metronomePlaying: Bool
    /// A follower's local mute, independent of whether the server's grid is playing.
    public let metronomeMuted: Bool
    public let metronomeLine: String
    public let metronomeBpm: Int
    public let whenAsked: ServerMetronome.WhenAsked
    public let selfMonitoring: Bool
    public let selfMonitoringStatus: String

    public init(connected: Bool, server: String, serverStatus: String, metronomeRole: ServerMetronome.Role,
                metronomePlaying: Bool, metronomeLine: String, metronomeBpm: Int, whenAsked: ServerMetronome.WhenAsked,
                selfMonitoring: Bool = false, selfMonitoringStatus: String = "Self-monitoring off.",
                metronomeMuted: Bool = false, serverDetails: String? = nil, pendingServer: String? = nil,
                masterName: String? = nil, masterBpm: Int? = nil, masterSignature: MetronomeSignature? = nil) {
        self.connected = connected
        self.pendingServer = pendingServer
        self.masterName = masterName
        self.masterBpm = masterBpm
        self.masterSignature = masterSignature
        self.server = server
        self.serverStatus = serverStatus
        self.serverDetails = serverDetails
        self.metronomeRole = metronomeRole
        self.metronomePlaying = metronomePlaying
        self.metronomeMuted = metronomeMuted
        self.metronomeLine = metronomeLine
        self.metronomeBpm = metronomeBpm
        self.whenAsked = whenAsked
        self.selfMonitoring = selfMonitoring
        self.selfMonitoringStatus = selfMonitoringStatus
    }
}

/// The server connection and the metronome, as the Mac's Session holds them (Session.swift, "Playing together through a
/// server"). The protocol itself lives in the RemSoundJam package, shared with the Windows-built tests.
final class SessionJam {
    var group: RelayGroupClient?
    let metronome = ServerMetronome()
    let clicks = MetronomeClickPlayer()
    /// Where the click is heard, and whether RemSound's recordings carry it (the profile's MetronomeChoices).
    var hearIn = MetronomeHearIn.remSound
    var clicksRecorded = false
    /// The DAW's own click players, one per plugin instance claiming "Metronome": each keeps its own last beat.
    var dawClicks: [UInt32: MetronomeClickPlayer] = [:]
    var serverEntry = ""
    var serverRequestID = UUID()
    var serverStatus = "Not connected to a server."
    var connectedSince: TimeInterval?
    var serverStatusState = ServerStatus.State()
    /// A server by name: the profile's own kept until it can be looked up, and one that has moved followed.
    var serverWatch = ServerNameWatch()
    /// Whether the connection under way is the person's own choice; false for the profile's server at start.
    var serverUserAsked = true
    var serverNetworkChanged = false
    var serverPathMonitor: NWPathMonitor?
    var serverPathSeen = false
    var nextNameCheck: TimeInterval = 0
    /// Capture timing per stream: the timeline, and how many frames have gone out on it.
    var timelines: [UInt16: CaptureTimeline] = [:]
    var framesOut: [UInt16: Int64] = [:]
    var reports = CaptureReportRing()
    var nextReport: TimeInterval = 0
    var replay = MetronomeReplayGuard()
    var metronomeSequence: UInt32 = 0
    var timedFrom = ""
    var lastView: JamView?
    var selfMonitor = SelfMonitorTiming()
    var selfMonitoringStatus = "Self-monitoring off."
    var lastAudioSentAt: TimeInterval = -.infinity
    var nextSelfMeasurement: TimeInterval = 0
    // Jamming at speed.
    var jamulusStyle = false
    var bufferFrames = 0
    var canDecode = CanDecodeRegistry()
    var customSender: OpusCustomSender?
    var customStreamID: UInt16 = 0
    var nextCustomFormat: TimeInterval = 0
    var ordinaryPending: [Float] = []
    var customSentThisSecond = 0
    // The last minute of the network, kept so it can be saved (Jamming > Save the Last Minute of the Network).
    var recorder: NetworkRecorder = {
        var r = NetworkRecorder()
        r.enabled = true
        return r
    }()
    let receiveTotals = ReceiveTotals()
    var nextRecorderSecond: TimeInterval = 0
    // The detailed log.
    var logFile: JamLog?
    var logFolder: URL?
    var nextLogSecond: TimeInterval = 0

    var onServer: Bool { group.flatMap { g in g.connectedRelay.map(g.isInGroup) } ?? false }

    /// When this packet's first sample was captured, from one reading of it (see CaptureTimeline), and the stream's frames
    /// moved on by the packet.
    func captureTime(stream: UInt16, frames: Int, readingUs: Int64) -> Int64 {
        let first = framesOut[stream] ?? 0
        var timeline = timelines[stream] ?? CaptureTimeline()
        let captured = timeline.captureTime(frameIndex: first, readingUs: readingUs)
        timelines[stream] = timeline
        framesOut[stream] = first + Int64(frames)
        return captured
    }

    func reset() {
        selfMonitor.stop()
        selfMonitoringStatus = "Self-monitoring off."
        lastAudioSentAt = -.infinity
        group = nil
        serverEntry = ""
        serverRequestID = UUID()
        serverStatus = "Not connected to a server."
        connectedSince = nil
        serverStatusState.reset()
        serverWatch = ServerNameWatch()
        serverUserAsked = true
        serverNetworkChanged = false
        serverPathMonitor?.cancel()
        serverPathMonitor = nil
        serverPathSeen = false
        nextNameCheck = 0
        timelines = [:]
        framesOut = [:]
        _ = reports.take()
        timedFrom = ""
    }
}

extension JamEndpoint {
    init(_ endpoint: Endpoint) { self.init(endpoint.address, endpoint.port) }
}

extension Endpoint {
    init(_ endpoint: JamEndpoint) { self.init(endpoint.address, endpoint.port) }
}
