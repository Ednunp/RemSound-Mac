// STAND-IN for the parts of ApplicationServices (CoreGraphics event taps, accessibility trust, CFMachPort run-loop
// sources) the app uses: declarations only, as Swift imports them. CGEventSource and CGKeyCode live in AppKit.swift.
@_exported import CoreFoundation
import Foundation

public func AXIsProcessTrusted() -> Bool { false }

public typealias CGEventMask = UInt64
public typealias CGEventTapProxy = OpaquePointer

public enum CGEventType: UInt32, Sendable {
    case null = 0, leftMouseDown = 1, leftMouseUp = 2, rightMouseDown = 3, rightMouseUp = 4, mouseMoved = 5
    case leftMouseDragged = 6, rightMouseDragged = 7, keyDown = 10, keyUp = 11, flagsChanged = 12, scrollWheel = 22
    case otherMouseDown = 25, otherMouseUp = 26, otherMouseDragged = 27
    case tapDisabledByTimeout = 0xFFFFFFFE, tapDisabledByUserInput = 0xFFFFFFFF
}
public enum CGEventTapLocation: UInt32, Sendable { case cghidEventTap = 0, cgSessionEventTap, cgAnnotatedSessionEventTap }
public enum CGEventTapPlacement: UInt32, Sendable { case headInsertEventTap = 0, tailAppendEventTap }
public enum CGEventTapOptions: UInt32, Sendable { case defaultTap = 0, listenOnly = 1 }
public enum CGEventField: UInt32, Sendable { case keyboardEventAutorepeat = 8, keyboardEventKeycode = 9, keyboardEventKeyboardType = 10 }
public struct CGEventFlags: OptionSet, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public static let maskAlphaShift = CGEventFlags(rawValue: 0x10000)
    public static let maskShift = CGEventFlags(rawValue: 0x20000)
    public static let maskControl = CGEventFlags(rawValue: 0x40000)
    public static let maskAlternate = CGEventFlags(rawValue: 0x80000)
    public static let maskCommand = CGEventFlags(rawValue: 0x100000)
    public static let maskSecondaryFn = CGEventFlags(rawValue: 0x800000)
    public static let maskNumericPad = CGEventFlags(rawValue: 0x200000)
}
public typealias CGEventTapCallBack = (CGEventTapProxy, CGEventType, CGEvent, UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>?

public final class CGEvent {
    public var flags: CGEventFlags = []
    public var timestamp: UInt64 { 0 }
    public var type: CGEventType { .null }
    public func getIntegerValueField(_ field: CGEventField) -> Int64 { 0 }
    public func setIntegerValueField(_ field: CGEventField, value: Int64) {}
    public static func tapCreate(tap: CGEventTapLocation, place: CGEventTapPlacement, options: CGEventTapOptions,
                                 eventsOfInterest: CGEventMask, callback: CGEventTapCallBack, userInfo: UnsafeMutableRawPointer?) -> CFMachPort? { nil }
    public static func tapEnable(tap: CFMachPort, enable: Bool) {}
    public static func tapIsEnabled(tap: CFMachPort) -> Bool { false }
}
