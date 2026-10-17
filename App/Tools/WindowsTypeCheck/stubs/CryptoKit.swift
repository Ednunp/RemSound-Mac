// STAND-IN for Apple's CryptoKit (AES-GCM and SymmetricKey only): declarations only, for type-checking on Windows.
import Foundation

public struct SymmetricKey {
    public init<D: ContiguousBytes>(data: D) {}
    public init(size: SymmetricKeySize) {}
    public var bitCount: Int { 256 }
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R { try body(UnsafeRawBufferPointer(start: nil, count: 0)) }
}
public struct SymmetricKeySize { public static let bits256 = SymmetricKeySize() }

public enum CryptoKitError: Error { case authenticationFailure, incorrectParameterSize }

public enum AES {
    public enum GCM {
        public struct Nonce: ContiguousBytes, Sequence {
            public init() {}
            public init<D: DataProtocol>(data: D) throws {}
            public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R { try body(UnsafeRawBufferPointer(start: nil, count: 0)) }
            public func makeIterator() -> Array<UInt8>.Iterator { [UInt8]().makeIterator() }
        }
        public struct SealedBox {
            public init<C: DataProtocol, T: DataProtocol>(nonce: Nonce, ciphertext: C, tag: T) throws {}
            public init<D: DataProtocol>(combined: D) throws {}
            public var nonce: Nonce { Nonce() }
            public var ciphertext: Data { Data() }
            public var tag: Data { Data() }
            public var combined: Data? { nil }
        }
        public static func seal<P: DataProtocol>(_ message: P, using key: SymmetricKey, nonce: Nonce? = nil) throws -> SealedBox { fatalError() }
        public static func seal<P: DataProtocol, A: DataProtocol>(_ message: P, using key: SymmetricKey, nonce: Nonce? = nil, authenticating: A) throws -> SealedBox { fatalError() }
        public static func open(_ sealedBox: SealedBox, using key: SymmetricKey) throws -> Data { Data() }
        public static func open<A: DataProtocol>(_ sealedBox: SealedBox, using key: SymmetricKey, authenticating: A) throws -> Data { Data() }
    }
}

// Hashes and HMAC, as the web listener and the plugin manifests use them.
public protocol Digest: Sequence, ContiguousBytes, Hashable, CustomStringConvertible where Element == UInt8 {}
public protocol HashFunction {
    associatedtype Digest: CryptoKit.Digest
    init()
    mutating func update<D: DataProtocol>(data: D)
    func finalize() -> Digest
    static func hash<D: DataProtocol>(data: D) -> Digest
}
public struct StandInDigest: Digest {
    public func makeIterator() -> Array<UInt8>.Iterator { [UInt8]().makeIterator() }
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R { try body(UnsafeRawBufferPointer(start: nil, count: 0)) }
    public var description: String { "" }
}
public struct SHA256: HashFunction {
    public typealias Digest = StandInDigest
    public init() {}
    public mutating func update<D: DataProtocol>(data: D) {}
    public func finalize() -> StandInDigest { StandInDigest() }
    public static func hash<D: DataProtocol>(data: D) -> StandInDigest { StandInDigest() }
}
public struct SHA512: HashFunction {
    public typealias Digest = StandInDigest
    public init() {}
    public mutating func update<D: DataProtocol>(data: D) {}
    public func finalize() -> StandInDigest { StandInDigest() }
    public static func hash<D: DataProtocol>(data: D) -> StandInDigest { StandInDigest() }
}
public enum Insecure {
    public struct SHA1: HashFunction {
        public typealias Digest = StandInDigest
        public init() {}
        public mutating func update<D: DataProtocol>(data: D) {}
        public func finalize() -> StandInDigest { StandInDigest() }
        public static func hash<D: DataProtocol>(data: D) -> StandInDigest { StandInDigest() }
    }
    public struct MD5: HashFunction {
        public typealias Digest = StandInDigest
        public init() {}
        public mutating func update<D: DataProtocol>(data: D) {}
        public func finalize() -> StandInDigest { StandInDigest() }
        public static func hash<D: DataProtocol>(data: D) -> StandInDigest { StandInDigest() }
    }
}
public struct HashedAuthenticationCode<H: HashFunction>: Sequence, ContiguousBytes, Hashable {
    public func makeIterator() -> Array<UInt8>.Iterator { [UInt8]().makeIterator() }
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R { try body(UnsafeRawBufferPointer(start: nil, count: 0)) }
    public var byteCount: Int { 0 }
}
public struct HMAC<H: HashFunction> {
    public init(key: SymmetricKey) {}
    public mutating func update<D: DataProtocol>(data: D) {}
    public func finalize() -> HashedAuthenticationCode<H> { HashedAuthenticationCode() }
    public static func authenticationCode<D: DataProtocol>(for data: D, using key: SymmetricKey) -> HashedAuthenticationCode<H> { HashedAuthenticationCode() }
    public static func isValidAuthenticationCode<D: DataProtocol>(_ mac: HashedAuthenticationCode<H>, authenticating data: D, using key: SymmetricKey) -> Bool { false }
    public static func isValidAuthenticationCode<C: ContiguousBytes, D: DataProtocol>(_ authenticationCode: C, authenticating data: D, using key: SymmetricKey) -> Bool { false }
}
