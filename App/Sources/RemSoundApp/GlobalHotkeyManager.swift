import AppKit
import Carbon
import Foundation

enum GlobalHotkeyAction: Int, CaseIterable {
    case showOrHide = 1
    case toggleSending = 2
    case toggleReceiving = 3
    case togglePlugins = 4
    // Remote volume and mute: sent to every peer we send to (Windows' six remote-control hotkeys, unset by default).
    case remoteVolumeUp = 5
    case remoteVolumeDown = 6
    case remoteMuteToggle = 7
    case remoteSystemVolumeUp = 8
    case remoteSystemVolumeDown = 9
    case remoteSystemMuteToggle = 10
    case toggleAllPeerShaping = 11
    case quickProfileSwitch = 12
    // The rest of Windows' Keyboard shortcuts (AppConfig's hotkeys), all unset unless chosen.
    case localVolumeUp = 13
    case localVolumeDown = 14
    case toggleRecording = 15
    case speakStatus = 16
    case metronomeStartStop = 17
    case metronomeTempoUp = 18
    case metronomeTempoDown = 19
    case metronomeVolumeUp = 20
    case metronomeVolumeDown = 21
    case hearMyself = 22
    case muteReceived = 23

    var settingKey: String {
        switch self {
        case .showOrHide: "showOrHide"
        case .toggleSending: "toggleSending"
        case .toggleReceiving: "toggleReceiving"
        case .togglePlugins: "togglePlugins"
        case .remoteVolumeUp: "remoteVolumeUp"
        case .remoteVolumeDown: "remoteVolumeDown"
        case .remoteMuteToggle: "remoteMuteToggle"
        case .remoteSystemVolumeUp: "remoteSystemVolumeUp"
        case .remoteSystemVolumeDown: "remoteSystemVolumeDown"
        case .remoteSystemMuteToggle: "remoteSystemMuteToggle"
        case .toggleAllPeerShaping: "toggleAllPeerShaping"
        case .quickProfileSwitch: "quickProfileSwitch"
        case .localVolumeUp: "localVolumeUp"
        case .localVolumeDown: "localVolumeDown"
        case .toggleRecording: "toggleRecording"
        case .speakStatus: "speakStatus"
        case .metronomeStartStop: "metronomeStartStop"
        case .metronomeTempoUp: "metronomeTempoUp"
        case .metronomeTempoDown: "metronomeTempoDown"
        case .metronomeVolumeUp: "metronomeVolumeUp"
        case .metronomeVolumeDown: "metronomeVolumeDown"
        case .hearMyself: "hearMyself"
        case .muteReceived: "muteReceived"
        }
    }

    /// The metronome's five, in the order its settings window lists them (Windows MetronomeSettingsDialog.KeyNames).
    static let metronomeKeys: [GlobalHotkeyAction] = [.metronomeStartStop, .metronomeTempoUp, .metronomeTempoDown,
                                                      .metronomeVolumeUp, .metronomeVolumeDown]

    /// Held down, these repeat at the keyboard's own rate, as the volume keys do (Windows lets them auto-repeat).
    var repeatsWhileHeld: Bool {
        [.remoteVolumeUp, .remoteVolumeDown, .remoteSystemVolumeUp, .remoteSystemVolumeDown, .localVolumeUp, .localVolumeDown,
         .metronomeTempoUp, .metronomeTempoDown, .metronomeVolumeUp, .metronomeVolumeDown].contains(self)
    }
}

@MainActor
final class GlobalHotkeyManager {
    var handler: ((GlobalHotkeyAction) -> Void)?
    private var references = [EventHotKeyRef?]()
    private var actionsByID = [UInt32: GlobalHotkeyAction]()
    private var bindings = [GlobalHotkeyAction: HotkeyDescriptor]()
    private var repeatTimer: Timer?
    /// Each registered id's key, to tell whether it is still held.
    private var keyCodesByID = [UInt32: UInt32]()
    nonisolated(unsafe) private static weak var current: GlobalHotkeyManager?

    init() {
        Self.current = self
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotkeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID)
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            DispatchQueue.main.async {
                guard let manager = GlobalHotkeyManager.current,
                    let action = manager.actionsByID[hotkeyID.id] else { return }
                if pressed { manager.pressed(action, id: hotkeyID.id) } else { manager.stopRepeating() }
            }
            return noErr
        }, 2, &eventTypes, nil, nil)
    }

    /// A press: the action once, then - for the volume keys - again at the keyboard's repeat rate after its repeat delay,
    /// for as long as the key is still down (checked every time, so a lost release never leaves it repeating).
    private func pressed(_ action: GlobalHotkeyAction, id: UInt32) {
        stopRepeating()
        handler?(action)
        guard action.repeatsWhileHeld else { return }
        let keyCode = keyCodesByID[id]
        repeatTimer = Timer.scheduledTimer(withTimeInterval: NSEvent.keyRepeatDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.repeatTimer = Timer.scheduledTimer(withTimeInterval: max(0.02, NSEvent.keyRepeatInterval),
                    repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        guard let keyCode, CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode)) else {
                            self.stopRepeating()
                            return
                        }
                        self.handler?(action)
                    }
                }
            }
        }
    }

    private func stopRepeating() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    func register(_ requested: [GlobalHotkeyAction: HotkeyDescriptor]) -> Bool {
        let values = Array(requested.values)
        guard values.allSatisfy(\.isValid), Set(values).count == values.count else {
            return false
        }
        let previous = bindings
        unregisterAll()
        if registerAll(requested) {
            bindings = requested
            return true
        }
        unregisterAll()
        _ = registerAll(previous)
        bindings = previous
        return false
    }

    private func registerAll(_ requested: [GlobalHotkeyAction: HotkeyDescriptor]) -> Bool {
        for action in GlobalHotkeyAction.allCases {
            guard let descriptor = requested[action] else { continue }
            var reference: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x52454D53), id: UInt32(action.rawValue))
            let result = RegisterEventHotKey(descriptor.keyCode,
                descriptor.modifiers.carbonFlags, id, GetApplicationEventTarget(),
                0, &reference)
            guard result == noErr else { return false }
            references.append(reference)
            actionsByID[id.id] = action
            keyCodesByID[id.id] = descriptor.keyCode
            // Clipman's UK/US keyboard fallback covers the backslash and ISO keys.
            for fallback in descriptor.layoutFallbacks where !requested.values.contains(fallback) {
                // Well clear of the actions' own ids (there are more than ten of them now).
                let aliasID = EventHotKeyID(signature: OSType(0x52454D53),
                    id: UInt32(action.rawValue + 100))
                var aliasReference: EventHotKeyRef?
                if RegisterEventHotKey(fallback.keyCode, fallback.modifiers.carbonFlags,
                    aliasID, GetApplicationEventTarget(), 0, &aliasReference) == noErr {
                    references.append(aliasReference)
                    actionsByID[aliasID.id] = action
                    keyCodesByID[aliasID.id] = fallback.keyCode
                }
            }
        }
        return true
    }

    private func unregisterAll() {
        stopRepeating()
        for reference in references {
            if let reference { UnregisterEventHotKey(reference) }
        }
        references.removeAll()
        actionsByID.removeAll()
        keyCodesByID.removeAll()
    }
}
