// STAND-IN for the parts of Core Foundation the app names that Windows' Swift lacks. The CF string, array, dictionary
// and type-ref stand-ins live in CoreAudio.swift (they were first needed there) and are re-exported from here, as
// Apple's frameworks re-export Core Foundation. Declarations only.
@_exported import CoreAudio
import Foundation

public typealias CFIndex = Int
public typealias CFTypeID = UInt
public typealias CFURL = URL
public final class CFAllocator {}
public let kCFAllocatorDefault: CFAllocator? = nil
public func CFGetTypeID(_ cf: CFTypeRef!) -> CFTypeID { 0 }
public func CFBooleanGetTypeID() -> CFTypeID { 0 }
public func CFStringGetLength(_ theString: CFString!) -> CFIndex { 0 }

public final class CFMachPort {}
public final class CFRunLoopSource {}
public final class CFRunLoop {}
public struct CFRunLoopMode: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let commonModes = CFRunLoopMode(rawValue: "kCFRunLoopCommonModes")
    public static let defaultMode = CFRunLoopMode(rawValue: "kCFRunLoopDefaultMode")
}
public func CFMachPortCreateRunLoopSource(_ allocator: CFAllocator?, _ port: CFMachPort!, _ order: CFIndex) -> CFRunLoopSource! { nil }
public func CFMachPortInvalidate(_ port: CFMachPort!) {}
public func CFMachPortIsValid(_ port: CFMachPort!) -> Bool { false }
public func CFRunLoopGetMain() -> CFRunLoop! { nil }
public func CFRunLoopGetCurrent() -> CFRunLoop! { nil }
public func CFRunLoopAddSource(_ rl: CFRunLoop!, _ source: CFRunLoopSource!, _ mode: CFRunLoopMode!) {}
public func CFRunLoopRemoveSource(_ rl: CFRunLoop!, _ source: CFRunLoopSource!, _ mode: CFRunLoopMode!) {}
public func CFRunLoopSourceInvalidate(_ source: CFRunLoopSource!) {}