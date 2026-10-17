// STAND-IN for Apple's Security (the keychain calls the app makes): declarations only, for type-checking on Windows.
@_exported import CoreAudio   // OSStatus, CFDictionary, CFTypeRef
import Foundation

public let kSecClass = "class"
public let kSecClassGenericPassword = "genp"
public let kSecAttrService = "svce"
public let kSecAttrAccount = "acct"
public let kSecValueData = "v_Data"
public let kSecReturnData = "r_Data"
public let kSecMatchLimit = "m_Limit"
public let kSecMatchLimitOne = "m_LimitOne"
public let kSecAttrAccessible = "pdmn"
public let kSecAttrAccessibleAfterFirstUnlock = "ck"
public var errSecSuccess: OSStatus { 0 }
public var errSecItemNotFound: OSStatus { -25300 }
public var errSecDuplicateItem: OSStatus { -25299 }
public var errSecInteractionNotAllowed: OSStatus { -25308 }
public var errSecAuthFailed: OSStatus { -25293 }

public func SecItemAdd(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus { 0 }
public func SecItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus { 0 }
public func SecItemUpdate(_ query: CFDictionary, _ attributesToUpdate: CFDictionary) -> OSStatus { 0 }
public func SecItemDelete(_ query: CFDictionary) -> OSStatus { 0 }
public func SecCopyErrorMessageString(_ status: OSStatus, _ reserved: UnsafeMutableRawPointer?) -> CFString? { nil }
public var errSecParam: OSStatus { -50 }

// Randomness.
public final class SecRandom {}
public let kSecRandomDefault: SecRandom? = nil
public func SecRandomCopyBytes(_ rnd: SecRandom?, _ count: Int, _ bytes: UnsafeMutableRawPointer) -> Int32 { 0 }

// Code signing: checking another program's signature before running it.
public final class SecCode {}
public final class SecStaticCode {}
public final class SecRequirement {}
public struct SecCSFlags: OptionSet, Sendable { public let rawValue: UInt32; public init(rawValue: UInt32) { self.rawValue = rawValue } }
public var kSecCSDefaultFlags: UInt32 { 0 }
public var kSecCSCheckAllArchitectures: UInt32 { 1 << 0 }
public var kSecCSCheckNestedCode: UInt32 { 1 << 3 }
public var kSecCSStrictValidate: UInt32 { 1 << 4 }
public var kSecCSRestrictSymlinks: UInt32 { 1 << 7 }
public var kSecCSSingleThreaded: UInt32 { 1 << 12 }
public var kSecCSSigningInformation: UInt32 { 1 << 1 }
public let kSecCodeInfoIdentifier: CFString = "identifier"
public let kSecCodeInfoMainExecutable: CFString = "main-executable"
public let kSecCodeInfoPList: CFString = "info-plist"
public let kSecCodeInfoTeamIdentifier: CFString = "teamid"
public let kSecCodeInfoUnique: CFString = "unique"
public let kSecGuestAttributePid: CFString = "pid"
public func SecStaticCodeCreateWithPath(_ path: URL, _ flags: SecCSFlags, _ staticCode: UnsafeMutablePointer<SecStaticCode?>) -> OSStatus { 0 }
public func SecStaticCodeCheckValidity(_ staticCode: SecStaticCode, _ flags: SecCSFlags, _ requirement: SecRequirement?) -> OSStatus { 0 }
public func SecRequirementCreateWithString(_ text: CFString, _ flags: SecCSFlags, _ requirement: UnsafeMutablePointer<SecRequirement?>) -> OSStatus { 0 }
public func SecCodeCopyGuestWithAttributes(_ host: SecCode?, _ attributes: CFDictionary?, _ flags: SecCSFlags, _ guest: UnsafeMutablePointer<SecCode?>) -> OSStatus { 0 }
public func SecCodeCheckValidity(_ code: SecCode, _ flags: SecCSFlags, _ requirement: SecRequirement?) -> OSStatus { 0 }
public func SecCodeCopySigningInformation(_ code: SecStaticCode, _ flags: SecCSFlags, _ information: UnsafeMutablePointer<CFDictionary?>) -> OSStatus { 0 }
public func SecCodeCopySigningInformation(_ code: SecCode, _ flags: SecCSFlags, _ information: UnsafeMutablePointer<CFDictionary?>) -> OSStatus { 0 }
public var kSecCSAllowNetworkAccess: UInt32 { 1 << 16 }
public var kSecCSDoNotValidateResources: UInt32 { 1 << 2 }
public var kSecCSDoNotValidateExecutable: UInt32 { 1 << 1 }
public func SecCodeCopyStaticCode(_ code: SecCode, _ flags: SecCSFlags, _ staticCode: UnsafeMutablePointer<SecStaticCode?>) -> OSStatus { 0 }
