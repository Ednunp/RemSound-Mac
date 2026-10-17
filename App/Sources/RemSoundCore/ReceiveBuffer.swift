import RemSoundJam

public enum ReceiveBuffer {
    public static let minimumMs = ReceiveTuning.minimumMs
    public static let maximumMs = ReceiveTuning.maximumMs
    public static let legacyDefaultMs = 20
    public static let choicesMs = ReceiveTuning.choicesMs
    public static let autoTuneIntervals = [3, 5, 10, 15, 30]
    public static let defaultAutoTuneInterval = 5

    public static func clamped(_ milliseconds: Int) -> Int { ReceiveTuning.clamped(milliseconds) }

    public static func validAutoTuneInterval(_ seconds: Int) -> Int {
        autoTuneIntervals.contains(seconds) ? seconds : defaultAutoTuneInterval
    }

    // The click-trim's limit and where it trims to are RemSoundJam's PlayoutQueue.excessLimitFrames and
    // trimDestinationFrames, beside the queue they trim.
}

// The auto-tune is RemSoundJam's (ReceiveAutoTune, Windows' decisions in WindowsAutoTune), so the simulator runs it too.
