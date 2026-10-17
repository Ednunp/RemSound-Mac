// STAND-IN for Apple's CommonCrypto key derivation: declarations only, as Swift imports them.
public typealias CCPBKDFAlgorithm = UInt32
public typealias CCPseudoRandomAlgorithm = UInt32
public var kCCPBKDF2: Int { 2 }
public var kCCPRFHmacAlgSHA1: Int { 1 }
public var kCCPRFHmacAlgSHA256: Int { 3 }
public var kCCPRFHmacAlgSHA512: Int { 5 }
public var kCCSuccess: Int { 0 }
public func CCKeyDerivationPBKDF(_ algorithm: CCPBKDFAlgorithm, _ password: UnsafePointer<CChar>!, _ passwordLen: Int,
    _ salt: UnsafePointer<UInt8>!, _ saltLen: Int, _ prf: CCPseudoRandomAlgorithm, _ rounds: UInt32,
    _ derivedKey: UnsafeMutablePointer<UInt8>!, _ derivedKeyLen: Int) -> Int32 { 0 }