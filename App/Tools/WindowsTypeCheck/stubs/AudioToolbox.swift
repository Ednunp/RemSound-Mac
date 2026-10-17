// STAND-IN for Apple's AudioToolbox (see CoreAudio.swift): declarations only, for type-checking on Windows.
@_exported import CoreAudio

public typealias AudioComponentInstance = OpaquePointer
public typealias AudioUnit = AudioComponentInstance
public typealias AudioUnitPropertyID = UInt32
public typealias AudioUnitScope = UInt32
public typealias AudioUnitElement = UInt32

public func AudioUnitSetProperty(_ inUnit: AudioUnit, _ inID: AudioUnitPropertyID, _ inScope: AudioUnitScope,
    _ inElement: AudioUnitElement, _ inData: UnsafeRawPointer?, _ inDataSize: UInt32) -> OSStatus { 0 }
public func AudioUnitGetProperty(_ inUnit: AudioUnit, _ inID: AudioUnitPropertyID, _ inScope: AudioUnitScope,
    _ inElement: AudioUnitElement, _ outData: UnsafeMutableRawPointer, _ ioDataSize: UnsafeMutablePointer<UInt32>) -> OSStatus { 0 }
public func AudioUnitGetPropertyInfo(_ inUnit: AudioUnit, _ inID: AudioUnitPropertyID, _ inScope: AudioUnitScope,
    _ inElement: AudioUnitElement, _ outDataSize: UnsafeMutablePointer<UInt32>?, _ outWritable: UnsafeMutablePointer<DarwinBoolean>?) -> OSStatus { 0 }

public var kAudioUnitScope_Global: AudioUnitScope { 0 }
public var kAudioUnitScope_Input: AudioUnitScope { 1 }
public var kAudioUnitScope_Output: AudioUnitScope { 2 }
public var kAudioOutputUnitProperty_CurrentDevice: AudioUnitPropertyID { 0 }
public var kAudioOutputUnitProperty_ChannelMap: AudioUnitPropertyID { 0 }
public var kAudioHardwareServiceDeviceProperty_VirtualMainVolume: AudioObjectPropertySelector { 0 }
