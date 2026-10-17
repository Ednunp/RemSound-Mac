import AudioToolbox
import CoreAudio
import Foundation
import RemSoundJam

/// The Mac's own output volume and mute, for a peer's remote commands (Windows' SystemVolumeHelper): the default output
/// device - what the menu bar's volume and the keyboard's volume keys move - a sixteenth a step, as those keys do.
/// A device with no volume or mute of its own (some HDMI and digital outputs) says no, and the log says ok=False.
public enum SystemVolume {
    private static func defaultOutput() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
            device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static func read<T>(_ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
        guard let device = defaultOutput() else { return nil }
        var a = address(selector)
        guard AudioObjectHasProperty(device, &a) else { return nil }
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func write<T>(_ selector: AudioObjectPropertySelector, _ value: T) -> Bool {
        guard let device = defaultOutput() else { return false }
        var a = address(selector)
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(device, &a), AudioObjectIsPropertySettable(device, &a, &settable) == noErr,
            settable.boolValue else { return false }
        var v = value
        return AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<T>.size), &v) == noErr
    }

    /// The volume (0...1) and mute, or nil if the default output has no volume to read.
    public static func state() -> (scalar: Float, muted: Bool)? {
        guard let scalar = read(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, Float32(0)) else { return nil }
        return (scalar, (read(kAudioDevicePropertyMute, UInt32(0)) ?? 0) != 0)
    }

    /// One step up or down. As on Windows, this does not unmute.
    public static func step(up: Bool) -> Bool {
        guard let scalar = read(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, Float32(0)) else { return false }
        return write(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            Float32(RemoteControl.steppedSystemVolume(scalar, up: up)))
    }

    public static func toggleMute() -> Bool {
        guard let muted = read(kAudioDevicePropertyMute, UInt32(0)) else { return false }
        return write(kAudioDevicePropertyMute, UInt32(muted == 0 ? 1 : 0))
    }
}
