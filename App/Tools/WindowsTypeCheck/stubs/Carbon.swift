// STAND-IN for the Carbon hot-key calls and virtual key codes the Mac app uses: declarations only, for type-checking
// on Windows. The constants are Int, as Swift imports Carbon's anonymous enums; the values are Apple's.
@_exported import CoreAudio   // OSStatus, noErr

public typealias OSType = UInt32
public typealias OptionBits = UInt32
public typealias EventParamName = OSType
public typealias EventParamType = OSType
public typealias ItemCount = Int
public typealias ByteCount = Int
public typealias EventHotKeyRef = OpaquePointer
public typealias EventTargetRef = OpaquePointer
public typealias EventRef = OpaquePointer
public typealias EventHandlerRef = OpaquePointer
public typealias EventHandlerCallRef = OpaquePointer
public typealias EventHandlerUPP = @convention(c) (EventHandlerCallRef?, EventRef?, UnsafeMutableRawPointer?) -> OSStatus

public struct EventHotKeyID { public var signature: OSType; public var id: UInt32
    public init() { signature = 0; id = 0 }
    public init(signature: OSType, id: UInt32) { self.signature = signature; self.id = id } }
public struct EventTypeSpec { public var eventClass: OSType; public var eventKind: UInt32
    public init() { eventClass = 0; eventKind = 0 }
    public init(eventClass: OSType, eventKind: UInt32) { self.eventClass = eventClass; self.eventKind = eventKind } }

@discardableResult public func InstallEventHandler(_ inTarget: EventTargetRef!, _ inHandler: EventHandlerUPP!, _ inNumTypes: ItemCount,
    _ inList: UnsafePointer<EventTypeSpec>!, _ inUserData: UnsafeMutableRawPointer!,
    _ outRef: UnsafeMutablePointer<EventHandlerRef?>!) -> OSStatus { 0 }
@discardableResult public func RemoveEventHandler(_ inHandlerRef: EventHandlerRef!) -> OSStatus { 0 }
public func GetApplicationEventTarget() -> EventTargetRef! { nil }
@discardableResult public func GetEventParameter(_ inEvent: EventRef!, _ inName: EventParamName, _ inDesiredType: EventParamType,
    _ outActualType: UnsafeMutablePointer<EventParamType>!, _ inBufferSize: ByteCount, _ outActualSize: UnsafeMutablePointer<ByteCount>!,
    _ outData: UnsafeMutableRawPointer!) -> OSStatus { 0 }
public func GetEventKind(_ inEvent: EventRef!) -> UInt32 { 0 }
public func GetEventClass(_ inEvent: EventRef!) -> OSType { 0 }
@discardableResult public func RegisterEventHotKey(_ inHotKeyCode: UInt32, _ inHotKeyModifiers: UInt32, _ inHotKeyID: EventHotKeyID,
    _ inTarget: EventTargetRef!, _ inOptions: OptionBits, _ outRef: UnsafeMutablePointer<EventHotKeyRef?>!) -> OSStatus { 0 }
@discardableResult public func UnregisterEventHotKey(_ inHotKey: EventHotKeyRef!) -> OSStatus { 0 }

public var kEventClassKeyboard: Int { 0x6B657962 }   // 'keyb'
public var kEventHotKeyPressed: Int { 5 }
public var kEventHotKeyReleased: Int { 6 }
public var kEventParamDirectObject: Int { 0x2D2D2D2D }   // '----'
public var typeEventHotKeyID: Int { 0x686B6964 }   // 'hkid'
public var cmdKey: Int { 0x100 }
public var shiftKey: Int { 0x200 }
public var optionKey: Int { 0x800 }
public var controlKey: Int { 0x1000 }

public var kVK_ANSI_A: Int { 0x00 }
public var kVK_ANSI_S: Int { 0x01 }
public var kVK_ANSI_D: Int { 0x02 }
public var kVK_ANSI_F: Int { 0x03 }
public var kVK_ANSI_H: Int { 0x04 }
public var kVK_ANSI_G: Int { 0x05 }
public var kVK_ANSI_Z: Int { 0x06 }
public var kVK_ANSI_X: Int { 0x07 }
public var kVK_ANSI_C: Int { 0x08 }
public var kVK_ANSI_V: Int { 0x09 }
public var kVK_ISO_Section: Int { 0x0A }
public var kVK_ANSI_B: Int { 0x0B }
public var kVK_ANSI_Q: Int { 0x0C }
public var kVK_ANSI_W: Int { 0x0D }
public var kVK_ANSI_E: Int { 0x0E }
public var kVK_ANSI_R: Int { 0x0F }
public var kVK_ANSI_Y: Int { 0x10 }
public var kVK_ANSI_T: Int { 0x11 }
public var kVK_ANSI_1: Int { 0x12 }
public var kVK_ANSI_2: Int { 0x13 }
public var kVK_ANSI_3: Int { 0x14 }
public var kVK_ANSI_4: Int { 0x15 }
public var kVK_ANSI_6: Int { 0x16 }
public var kVK_ANSI_5: Int { 0x17 }
public var kVK_ANSI_9: Int { 0x19 }
public var kVK_ANSI_7: Int { 0x1A }
public var kVK_ANSI_8: Int { 0x1C }
public var kVK_ANSI_0: Int { 0x1D }
public var kVK_ANSI_O: Int { 0x1F }
public var kVK_ANSI_U: Int { 0x20 }
public var kVK_ANSI_I: Int { 0x22 }
public var kVK_ANSI_P: Int { 0x23 }
public var kVK_Return: Int { 0x24 }
public var kVK_ANSI_L: Int { 0x25 }
public var kVK_ANSI_J: Int { 0x26 }
public var kVK_ANSI_K: Int { 0x28 }
public var kVK_ANSI_Backslash: Int { 0x2A }
public var kVK_ANSI_N: Int { 0x2D }
public var kVK_ANSI_M: Int { 0x2E }
public var kVK_Tab: Int { 0x30 }
public var kVK_Space: Int { 0x31 }
public var kVK_ANSI_Grave: Int { 0x32 }
public var kVK_Delete: Int { 0x33 }
public var kVK_Escape: Int { 0x35 }
public var kVK_Shift: Int { 0x38 }
public var kVK_RightShift: Int { 0x3C }
public var kVK_F5: Int { 0x60 }
public var kVK_F6: Int { 0x61 }
public var kVK_F7: Int { 0x62 }
public var kVK_F3: Int { 0x63 }
public var kVK_F8: Int { 0x64 }
public var kVK_F9: Int { 0x65 }
public var kVK_F11: Int { 0x67 }
public var kVK_F10: Int { 0x6D }
public var kVK_F12: Int { 0x6F }
public var kVK_ForwardDelete: Int { 0x75 }
public var kVK_F4: Int { 0x76 }
public var kVK_F2: Int { 0x78 }
public var kVK_F1: Int { 0x7A }
public var kVK_ANSI_KeypadEnter: Int { 0x4C }
public var kVK_LeftArrow: Int { 0x7B }
public var kVK_RightArrow: Int { 0x7C }
public var kVK_DownArrow: Int { 0x7D }
public var kVK_UpArrow: Int { 0x7E }
public var kVK_Home: Int { 0x73 }
public var kVK_End: Int { 0x77 }
public var kVK_PageUp: Int { 0x74 }
public var kVK_PageDown: Int { 0x79 }
