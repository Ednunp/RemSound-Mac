import AppKit
import Carbon
import RemSoundJam
import RemSoundCore

/// Return moves a slider through its normal action, including the owner's persistence and value description.
final class ResettableSlider: NSSlider {
    private static let defaultVolume = 100.0
    private static let defaultMetronomeVolume = Double(ConnectionProfile.defaultMetronomeVolume)
    private static let centrePan = 0.0
    private static let flatEqualizer = 50.0

    var resetValue: Double?
    var logReset: ((Double, Double) -> Void)?
    var notifyResetValue: (ResettableSlider) -> Void = { slider in
        guard AppRuntime.configuration?.silent == false else { return }
        NSAccessibility.post(element: slider.cell as Any? ?? slider, notification: .valueChanged)
    }

    static func volume() -> ResettableSlider {
        make(defaultValue: defaultVolume, minimum: 0, maximum: 100)
    }

    static func pushToTalkThreshold() -> ResettableSlider {
        make(defaultValue: Double(PushToTalkGateConfiguration.defaultLevelDb),
             minimum: Double(PushToTalkGateConfiguration.minimumLevelDb), maximum: Double(PushToTalkGateConfiguration.maximumLevelDb))
    }
    static func metronomeVolume() -> ResettableSlider {
        make(defaultValue: defaultMetronomeVolume, minimum: 0, maximum: 100)
    }

    static func pan() -> ResettableSlider {
        make(defaultValue: centrePan, minimum: -100, maximum: 100)
    }

    static func equalizerBand() -> ResettableSlider {
        make(defaultValue: flatEqualizer, minimum: 0, maximum: 100)
    }

    private static func make(defaultValue: Double, minimum: Double, maximum: Double) -> ResettableSlider {
        let slider = ResettableSlider(value: defaultValue, minValue: minimum, maxValue: maximum,
            target: nil, action: nil)
        slider.resetValue = defaultValue
        return slider
    }

    /// The window calls this before default-button dispatch, and only for its focused slider.
    @discardableResult
    func resetIfRequested(by event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard event.type == .keyDown, modifiers.isEmpty,
            event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter),
            isEnabled, !isHiddenOrHasHiddenAncestor, let resetValue, resetValue.isFinite else { return false }
        let value = min(maxValue, max(minValue, resetValue))
        guard doubleValue != value else { return true }
        let previous = doubleValue
        doubleValue = value
        sendAction(action, to: target)
        logReset?(previous, value)
        // Owners can update the accessible name in their action; announce the completed state afterward.
        notifyResetValue(self)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if resetIfRequested(by: event) { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, resetIfRequested(by: event) { return true }
        return super.performKeyEquivalent(with: event)
    }
}
