// STAND-IN for Apple's dns_sd (DNSServiceGetAddrInfo and friends): declarations only, as Swift imports them.
import Darwin
import Dispatch

public typealias DNSServiceRef = OpaquePointer
public typealias DNSServiceFlags = UInt32
public typealias DNSServiceErrorType = Int32
public typealias DNSServiceProtocol = UInt32
public var kDNSServiceFlagsAdd: Int { 0x2 }
public var kDNSServiceFlagsMoreComing: Int { 0x1 }
public var kDNSServiceFlagsTimeout: Int { 0x10000 }
public var kDNSServiceFlagsReturnIntermediates: Int { 0x1000 }
public var kDNSServiceProtocol_IPv4: Int { 0x01 }
public var kDNSServiceProtocol_IPv6: Int { 0x02 }
public var kDNSServiceErr_NoError: Int { 0 }
public var kDNSServiceErr_NoSuchRecord: Int { -65554 }
public typealias DNSServiceGetAddrInfoReply = (DNSServiceRef?, DNSServiceFlags, UInt32, DNSServiceErrorType,
    UnsafePointer<CChar>?, UnsafePointer<sockaddr>?, UInt32, UnsafeMutableRawPointer?) -> Void
public func DNSServiceGetAddrInfo(_ sdRef: UnsafeMutablePointer<DNSServiceRef?>!, _ flags: DNSServiceFlags, _ interfaceIndex: UInt32,
    _ protocol: DNSServiceProtocol, _ hostname: UnsafePointer<CChar>!, _ callBack: DNSServiceGetAddrInfoReply!,
    _ context: UnsafeMutableRawPointer!) -> DNSServiceErrorType { 0 }
public func DNSServiceRefDeallocate(_ sdRef: DNSServiceRef!) {}
public func DNSServiceSetDispatchQueue(_ service: DNSServiceRef!, _ queue: DispatchQueue!) -> DNSServiceErrorType { 0 }
public func DNSServiceProcessResult(_ sdRef: DNSServiceRef!) -> DNSServiceErrorType { 0 }
public func DNSServiceRefSockFD(_ sdRef: DNSServiceRef!) -> Int32 { 0 }