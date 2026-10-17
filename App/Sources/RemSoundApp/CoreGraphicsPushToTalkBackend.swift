import AppKit
import ApplicationServices
import RemSoundRuntime

/// Active session filter, on the main run loop. No text or unrelated key is retained or logged.
@MainActor
final class CoreGraphicsPushToTalkBackend: PushToTalkRegistrationBackend {
    private let configuration: RuntimeConfiguration
    private let preflight: () -> Bool
    init(configuration: RuntimeConfiguration, preflight: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.configuration = configuration
        self.preflight = preflight
    }
    private enum Failure: LocalizedError {
        case isolated, permission, registration
        var errorDescription: String? {
            switch self {
            case .isolated: return "Global push-to-talk keys are unavailable in this isolated or silent copy."
            case .permission: return "Allow RemSound in macOS Accessibility settings before using a global push-to-talk key."
            case .registration: return "The global push-to-talk key listener could not be started."
            }
        }
    }
    func install(receive: @escaping (PushToTalkNativeKeyEvent) -> Bool,
                 disabled: @escaping () -> Void) throws -> PushToTalkRegistrationLifetime {
        // Refuse before permission queries or native resources. Tests never install a real input listener.
        guard configuration.allowsGlobalHotkeys, !configuration.silent, !configuration.isHeadless else { throw Failure.isolated }
        guard preflight() else { throw Failure.permission }
        let callbacks = Callbacks(receive: receive, disabled: disabled)
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                // The source is installed only on the main run loop; retain callbacks locally during stop/reentry.
                let callbacks = Unmanaged<Callbacks>.fromOpaque(refcon).takeUnretainedValue()
                return MainActor.assumeIsolated {
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        callbacks.disabled?()
                        return Unmanaged.passUnretained(event)
                    }
                    guard type == .keyDown || type == .keyUp else { return Unmanaged.passUnretained(event) }
                    let rawKey = event.getIntegerValueField(.keyboardEventKeycode)
                    guard rawKey >= 0, rawKey <= Int64(UInt16.max) else { return Unmanaged.passUnretained(event) }
                    var modifiers: HotkeyDescriptor.Modifiers = []
                    if event.flags.contains(.maskControl) { modifiers.insert(.control) }
                    if event.flags.contains(.maskAlternate) { modifiers.insert(.option) }
                    if event.flags.contains(.maskCommand) { modifiers.insert(.command) }
                    if event.flags.contains(.maskShift) { modifiers.insert(.shift) }
                    let key = PushToTalkNativeKeyEvent(keyCode: UInt32(rawKey), modifiers: modifiers,
                        down: type == .keyDown, isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                        milliseconds: Int64(clamping: event.timestamp / 1_000_000))
                    return callbacks.receive?(key) == true ? nil : Unmanaged.passUnretained(event)
                }
            }, userInfo: Unmanaged.passUnretained(callbacks).toOpaque()) else { throw Failure.registration }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            throw Failure.registration
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return Lifetime(port: port, source: source, callbacks: callbacks)
    }
    private final class Callbacks {
        var receive: ((PushToTalkNativeKeyEvent) -> Bool)?
        var disabled: (() -> Void)?
        init(receive: @escaping (PushToTalkNativeKeyEvent) -> Bool, disabled: @escaping () -> Void) {
            self.receive = receive; self.disabled = disabled
        }
    }
    private final class Lifetime: PushToTalkRegistrationLifetime {
        private var port: CFMachPort?
        private var source: CFRunLoopSource?
        private let callbacks: Callbacks
        init(port: CFMachPort, source: CFRunLoopSource, callbacks: Callbacks) {
            self.port = port; self.source = source; self.callbacks = callbacks
        }
        func stop() {
            callbacks.receive = nil; callbacks.disabled = nil
            if let port { CGEvent.tapEnable(tap: port, enable: false) }
            if let source {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
                CFRunLoopSourceInvalidate(source)
            }
            if let port { CFMachPortInvalidate(port) }
            source = nil; port = nil
        }
        deinit {
            if let source {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
                CFRunLoopSourceInvalidate(source)
            }
            if let port { CFMachPortInvalidate(port) }
        }
    }
}
