import Foundation
import RemSoundJam

/// Profile-scoped PTT choices. The machine-wide key and transient held/latch state are deliberately absent.
public struct PushToTalkSettings: Codable, Equatable {
    public var enabled = false
    public var capturePath: PushToTalkCapturePath = .both
    public var trigger: PushToTalkTrigger = .key
    public var holdToSpeak = true
    public var doubleTapToHold = true
    public var doubleTapSpeed: PushToTalkDoubleTapSpeed = .medium
    private var storedLevelDb = PushToTalkGateConfiguration.defaultLevelDb
    public var levelDb: Int {
        get { storedLevelDb }
        set { storedLevelDb = max(PushToTalkGateConfiguration.minimumLevelDb,
                                 min(PushToTalkGateConfiguration.maximumLevelDb, newValue)) }
    }
    public var bypassForRecording = false
    public var bypassForPlugin = false
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, capturePath, trigger, holdToSpeak, doubleTapToHold, doubleTapSpeed,
             levelDb, bypassForRecording, bypassForPlugin
    }
    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        capturePath = try values.decodeIfPresent(PushToTalkCapturePath.self, forKey: .capturePath) ?? .both
        trigger = try values.decodeIfPresent(PushToTalkTrigger.self, forKey: .trigger) ?? .key
        holdToSpeak = try values.decodeIfPresent(Bool.self, forKey: .holdToSpeak) ?? true
        doubleTapToHold = try values.decodeIfPresent(Bool.self, forKey: .doubleTapToHold) ?? true
        doubleTapSpeed = try values.decodeIfPresent(PushToTalkDoubleTapSpeed.self, forKey: .doubleTapSpeed) ?? .medium
        levelDb = try values.decodeIfPresent(Int.self, forKey: .levelDb) ?? PushToTalkGateConfiguration.defaultLevelDb
        bypassForRecording = try values.decodeIfPresent(Bool.self, forKey: .bypassForRecording) ?? false
        bypassForPlugin = try values.decodeIfPresent(Bool.self, forKey: .bypassForPlugin) ?? false
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(enabled, forKey: .enabled)
        try values.encode(capturePath, forKey: .capturePath)
        try values.encode(trigger, forKey: .trigger)
        try values.encode(holdToSpeak, forKey: .holdToSpeak)
        try values.encode(doubleTapToHold, forKey: .doubleTapToHold)
        try values.encode(doubleTapSpeed, forKey: .doubleTapSpeed)
        try values.encode(levelDb, forKey: .levelDb)
        try values.encode(bypassForRecording, forKey: .bypassForRecording)
        try values.encode(bypassForPlugin, forKey: .bypassForPlugin)
    }
    public var gateConfiguration: PushToTalkGateConfiguration {
        var result = PushToTalkGateConfiguration()
        result.enabled = enabled; result.capturePath = capturePath; result.trigger = trigger
        result.levelDb = levelDb
        result.bypassForRecording = bypassForRecording; result.bypassForPlugin = bypassForPlugin
        return result
    }
}
