// STAND-IN for Apple's CoreAudio (with the MacTypes and CoreFoundation bits the Mac code uses), so the Mac engine's
// Swift can be TYPE-CHECKED on Windows. Declarations only - nothing here runs. The signatures follow Apple's SDK as
// Swift imports it; where one is only approximate a type error that involves it may be this file's, not the app's.
@_exported import Foundation
@_exported import CoreAudioC   // the C structs and the IOProc type, as C

public var noErr: OSStatus { 0 }

// CoreFoundation, as far as the Mac code bridges to it (it only ever casts to and from Swift types).
public typealias CFString = String
public typealias CFArray = [Any]
public typealias CFDictionary = [String: Any]
public typealias CFTypeRef = AnyObject

public struct DarwinBoolean: ExpressibleByBooleanLiteral {
    public var boolValue: Bool
    public init(_ value: Bool) { boolValue = value }
    public init(booleanLiteral value: Bool) { boolValue = value }
}

public typealias AudioDeviceID = AudioObjectID
public typealias AudioStreamID = AudioObjectID

public struct UnsafeMutableAudioBufferListPointer: MutableCollection, RandomAccessCollection {
    public init(_ p: UnsafeMutablePointer<AudioBufferList>) { unsafeMutablePointer = p }
    public init?(_ p: UnsafeMutablePointer<AudioBufferList>?) { guard let p else { return nil }; unsafeMutablePointer = p }
    public var unsafeMutablePointer: UnsafeMutablePointer<AudioBufferList>
    public var unsafePointer: UnsafePointer<AudioBufferList> { UnsafePointer(unsafeMutablePointer) }
    public var count: Int { get { 0 } nonmutating set {} }
    public var startIndex: Int { 0 }
    public var endIndex: Int { 0 }
    public subscript(index: Int) -> AudioBuffer {
        get { AudioBuffer() }
        nonmutating set {}
    }
}

public func AudioObjectGetPropertyData(_ inObjectID: AudioObjectID, _ inAddress: UnsafePointer<AudioObjectPropertyAddress>,
    _ inQualifierDataSize: UInt32, _ inQualifierData: UnsafeRawPointer?, _ ioDataSize: UnsafeMutablePointer<UInt32>,
    _ outData: UnsafeMutableRawPointer) -> OSStatus { 0 }
public func AudioObjectGetPropertyDataSize(_ inObjectID: AudioObjectID, _ inAddress: UnsafePointer<AudioObjectPropertyAddress>,
    _ inQualifierDataSize: UInt32, _ inQualifierData: UnsafeRawPointer?, _ outDataSize: UnsafeMutablePointer<UInt32>) -> OSStatus { 0 }
public func AudioObjectSetPropertyData(_ inObjectID: AudioObjectID, _ inAddress: UnsafePointer<AudioObjectPropertyAddress>,
    _ inQualifierDataSize: UInt32, _ inQualifierData: UnsafeRawPointer?, _ inDataSize: UInt32, _ inData: UnsafeRawPointer) -> OSStatus { 0 }
public func AudioObjectHasProperty(_ inObjectID: AudioObjectID, _ inAddress: UnsafePointer<AudioObjectPropertyAddress>) -> Bool { false }
public func AudioObjectIsPropertySettable(_ inObjectID: AudioObjectID, _ inAddress: UnsafePointer<AudioObjectPropertyAddress>,
    _ outIsSettable: UnsafeMutablePointer<DarwinBoolean>) -> OSStatus { 0 }
public func AudioDeviceCreateIOProcID(_ inDevice: AudioObjectID, _ inProc: AudioDeviceIOProc, _ inClientData: UnsafeMutableRawPointer?,
    _ outIOProcID: UnsafeMutablePointer<AudioDeviceIOProcID?>) -> OSStatus { 0 }
public typealias AudioDeviceIOBlock = (UnsafePointer<AudioTimeStamp>, UnsafePointer<AudioBufferList>,
    UnsafePointer<AudioTimeStamp>, UnsafeMutablePointer<AudioBufferList>, UnsafePointer<AudioTimeStamp>) -> Void
public func AudioDeviceCreateIOProcIDWithBlock(_ outIOProcID: UnsafeMutablePointer<AudioDeviceIOProcID?>,
    _ inDevice: AudioObjectID, _ inDispatchQueue: DispatchQueue?, _ inIOBlock: @escaping AudioDeviceIOBlock) -> OSStatus { 0 }
public func AudioDeviceDestroyIOProcID(_ inDevice: AudioObjectID, _ inIOProcID: AudioDeviceIOProcID) -> OSStatus { 0 }
public func AudioDeviceStart(_ inDevice: AudioObjectID, _ inProcID: AudioDeviceIOProcID?) -> OSStatus { 0 }
public func AudioDeviceStop(_ inDevice: AudioObjectID, _ inProcID: AudioDeviceIOProcID?) -> OSStatus { 0 }
public func AudioHardwareCreateAggregateDevice(_ inDescription: CFDictionary, _ outDeviceID: UnsafeMutablePointer<AudioObjectID>) -> OSStatus { 0 }
public func AudioHardwareDestroyAggregateDevice(_ inDeviceID: AudioObjectID) -> OSStatus { 0 }
public func AudioHardwareCreateProcessTap(_ inDescription: CATapDescription?, _ outTapID: UnsafeMutablePointer<AudioObjectID>?) -> OSStatus { 0 }
public func AudioHardwareDestroyProcessTap(_ inTapID: AudioObjectID) -> OSStatus { 0 }

open class CATapDescription: NSObject {
    public init(stereoGlobalTapButExcludeProcesses processes: [AudioObjectID]) {}
    public init(excludingProcesses processes: [AudioObjectID], deviceUID: String, stream: UInt) {}
    public init(stereoMixdownOfProcesses processes: [AudioObjectID]) {}
    public init(processes: [AudioObjectID], andDeviceUID deviceUID: String, withStream stream: UInt) {}
    open var name: String = ""
    open var isPrivate: Bool = false
    open var isExclusive: Bool = false
    open var isMixdown: Bool = false
    open var isMono: Bool = false
    open var deviceUID: String?
    open var stream: NSNumber?
    open var processes: [AudioObjectID] = []
    open var uuid: UUID = UUID()
    open var muteBehavior: CATapMuteBehavior = .unmuted
}
public enum CATapMuteBehavior: Int { case unmuted = 0, muted = 1, mutedWhenTapped = 2 }

public var kAudioObjectSystemObject: Int { 1 }
public var kAudioObjectUnknown: AudioObjectID { 0 }
public var kAudioObjectPropertyScopeGlobal: AudioObjectPropertyScope { 0 }
public var kAudioObjectPropertyScopeInput: AudioObjectPropertyScope { 0 }
public var kAudioObjectPropertyScopeOutput: AudioObjectPropertyScope { 0 }
public var kAudioObjectPropertyElementMain: AudioObjectPropertyElement { 0 }
public var kAudioObjectPropertyName: AudioObjectPropertySelector { 0 }
public var kAudioDevicePropertyScopeInput: AudioObjectPropertyScope { 0 }
public var kAudioDevicePropertyScopeOutput: AudioObjectPropertyScope { 0 }
public var kAudioHardwarePropertyDevices: AudioObjectPropertySelector { 0 }
public var kAudioHardwarePropertyDefaultInputDevice: AudioObjectPropertySelector { 0 }
public var kAudioHardwarePropertyDefaultOutputDevice: AudioObjectPropertySelector { 0 }
public var kAudioHardwarePropertyProcessObjectList: AudioObjectPropertySelector { 0 }
public var kAudioDevicePropertyStreams: AudioObjectPropertySelector { 0 }
public var kAudioDevicePropertyBufferFrameSize: AudioObjectPropertySelector { 0 }
public var kAudioDevicePropertyDeviceUID: AudioObjectPropertySelector { 0 }
public var kAudioDevicePropertyDeviceIsAlive: AudioObjectPropertySelector { 0 }
public var kAudioDevicePropertyMute: AudioObjectPropertySelector { 0 }
public var kAudioDevicePropertyStreamConfiguration: AudioObjectPropertySelector { 0 }
public var kAudioDevicePropertyNominalSampleRate: AudioObjectPropertySelector { 0 }
public var kAudioDevicePropertyLatency: AudioObjectPropertySelector { 0 }
public var kAudioDevicePropertyActualSampleRate: AudioObjectPropertySelector { 0 }
public var kAudioStreamPropertyLatency: AudioObjectPropertySelector { 0 }
public var kAudioDevicePropertySafetyOffset: AudioObjectPropertySelector { 0 }
public var kAudioStreamPropertyVirtualFormat: AudioObjectPropertySelector { 0 }
public var kAudioStreamPropertyPhysicalFormat: AudioObjectPropertySelector { 0 }
public var kAudioProcessPropertyPID: AudioObjectPropertySelector { 0 }
public var kAudioProcessPropertyBundleID: AudioObjectPropertySelector { 0 }
public var kAudioProcessPropertyIsRunningOutput: AudioObjectPropertySelector { 0 }
public var kAudioTapPropertyUID: AudioObjectPropertySelector { 0 }
public var kAudioTapPropertyFormat: AudioObjectPropertySelector { 0 }
public var kAudioAggregateDevicePropertyTapList: AudioObjectPropertySelector { 0 }
public var kAudioFormatLinearPCM: AudioFormatID { 0 }
public var kAudioFormatFLAC: AudioFormatID { 0 }
public var kAudioFormatFlagIsFloat: AudioFormatFlags { 0 }
public var kAudioFormatFlagIsNonInterleaved: AudioFormatFlags { 0 }
public var kAudioFormatFlagIsPacked: AudioFormatFlags { 0 }
public var kAudioFormatFlagIsSignedInteger: AudioFormatFlags { 0 }
public let kAudioAggregateDeviceNameKey = "name"
public let kAudioAggregateDeviceUIDKey = "uid"
public let kAudioAggregateDeviceIsPrivateKey = "private"
public let kAudioAggregateDeviceTapAutoStartKey = "tapautostart"
public let kAudioAggregateDeviceTapListKey = "taps"
public let kAudioAggregateDeviceSubDeviceListKey = "subdevices"
public let kAudioSubTapUIDKey = "uid"
