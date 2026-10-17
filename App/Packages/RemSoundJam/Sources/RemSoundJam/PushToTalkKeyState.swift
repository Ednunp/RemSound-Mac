/// The Windows-compatible interval between two distinct PTT key presses.
public enum PushToTalkDoubleTapSpeed: Int, Codable, CaseIterable {
    case slow = 0, medium = 1, fast = 2

    public var maximumIntervalMilliseconds: Int64 {
        switch self {
        case .slow: return 900
        case .medium: return 500
        case .fast: return 300
        }
    }
}

/// Pure key policy, owned by the keyboard/session controller; it never installs a hook or opens audio.
/// A double tap latches talking; one subsequent tap releases it. Key repeats are ignored.
public struct PushToTalkKeyState {
    private var holdToSpeak = true
    private var doubleTapToHold = true
    private var doubleTapMilliseconds = PushToTalkDoubleTapSpeed.medium.maximumIntervalMilliseconds
    private var keyDown = false
    private var latched = false
    private var toggled = false
    private var lastPressMilliseconds: Int64 = 0
    private var havePress = false
    public private(set) var talking = false

    public init() {}

    /// Changing rules clears held, latched and pending presses, starting from silence.
    public mutating func configure(holdToSpeak: Bool, doubleTapToHold: Bool,
                                   speed: PushToTalkDoubleTapSpeed = .medium) {
        self.holdToSpeak = holdToSpeak
        self.doubleTapToHold = doubleTapToHold
        doubleTapMilliseconds = speed.maximumIntervalMilliseconds
        reset()
    }

    public mutating func reset() {
        keyDown = false
        latched = false
        toggled = false
        havePress = false
        lastPressMilliseconds = 0
        talking = false
    }

    /// Use a caller-owned monotonic millisecond clock. Returns whether talking changed.
    @discardableResult public mutating func press(atMilliseconds milliseconds: Int64) -> Bool {
        guard !keyDown else { return false }
        keyDown = true
        let elapsed = milliseconds.subtractingReportingOverflow(lastPressMilliseconds)
        let isDouble = havePress && !elapsed.overflow && elapsed.partialValue >= 0
            && elapsed.partialValue <= doubleTapMilliseconds
        // Consume pairs and release taps so a third fast press cannot reuse either one.
        havePress = !isDouble
        lastPressMilliseconds = milliseconds
        if !holdToSpeak && !doubleTapToHold { toggled.toggle() }
        else if doubleTapToHold && latched {
            latched = false
            havePress = false
        } else if doubleTapToHold && isDouble { latched = true }
        return recompute()
    }

    /// A release needs no timestamp: double taps are measured between distinct presses.
    @discardableResult public mutating func release() -> Bool {
        guard keyDown else { return false }
        keyDown = false
        return recompute()
    }

    private mutating func recompute() -> Bool {
        let previous = talking
        talking = !holdToSpeak && !doubleTapToHold ? toggled
            : (holdToSpeak && keyDown) || (doubleTapToHold && latched)
        return talking != previous
    }
}
