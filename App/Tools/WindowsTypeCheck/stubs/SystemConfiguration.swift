@_exported import CoreAudio
// STAND-IN for read-only interface descriptions: declarations only, never a routing implementation.
public struct SCNetworkInterface {}
public func SCNetworkInterfaceCopyAll() -> [Any]? { nil }
public func SCNetworkInterfaceGetBSDName(_ interface: SCNetworkInterface) -> String? { nil }
public func SCNetworkInterfaceGetInterfaceType(_ interface: SCNetworkInterface) -> String? { nil }
public final class SCDynamicStore {}
public typealias CFPropertyList = AnyObject
public func SCDynamicStoreCopyValue(_ store: SCDynamicStore?, _ key: CFString) -> CFPropertyList? { nil }
