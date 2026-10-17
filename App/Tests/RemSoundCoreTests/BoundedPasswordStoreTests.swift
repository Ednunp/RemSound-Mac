import XCTest
import Security
@testable import RemSoundCore

final class BoundedPasswordStoreTests: XCTestCase {
    func testAbsentAndValidBoundedCredentialRoundTripWithoutNormalization() throws {
        let store = PasswordStore(ephemeral: true); XCTAssertNil(try store.load(maximumUTF8Bytes: 1024))
        let value = " e\u{301}\0é "; try store.save(value); XCTAssertEqual(try store.load(maximumUTF8Bytes: 1024), value)
    }
    func testExactUnicodeByteBoundaryAndOversizeFailWithoutTruncationOrDeletion() throws {
        let store = PasswordStore(ephemeral: true), exact = String(repeating: "é", count: 512)
        try store.save(exact); XCTAssertEqual(try store.load(maximumUTF8Bytes: 1024), exact)
        try store.save(exact + "a"); XCTAssertThrowsError(try store.load(maximumUTF8Bytes: 1024)); XCTAssertEqual(try store.load(), exact + "a")
    }
    func testInvalidLimitsRefuseWithoutChangingStoredValue() throws {
        let store = PasswordStore(ephemeral: true); try store.save("synthetic")
        for limit in [-1,0,1025,Int.max] { XCTAssertThrowsError(try store.load(maximumUTF8Bytes: limit)) { XCTAssertEqual(($0 as? PasswordStoreError)?.status, errSecParam) } }
        XCTAssertEqual(try store.load(), "synthetic")
    }
    func testCallerCanChooseSmallerPositiveByteCap() throws {
        let store = PasswordStore(ephemeral: true); try store.save("é")
        XCTAssertThrowsError(try store.load(maximumUTF8Bytes: 1)); XCTAssertEqual(try store.load(maximumUTF8Bytes: 2), "é")
    }
    func testOriginalUnboundedAPIKeepsCompatibilityAndIndependentStore() throws {
        let first = PasswordStore(ephemeral: true), second = PasswordStore(ephemeral: true)
        let value = String(repeating: "x", count: 2048); try first.save(value)
        XCTAssertEqual(try first.load(), value); XCTAssertThrowsError(try first.load(maximumUTF8Bytes: 1024)); XCTAssertNil(try second.load(maximumUTF8Bytes: 1024))
    }
    func testDeleteAfterBoundedRefusalRestoresAbsence() throws {
        let store = PasswordStore(ephemeral: true); try store.save("synthetic"); XCTAssertThrowsError(try store.load(maximumUTF8Bytes: 1))
        try store.delete(); XCTAssertNil(try store.load(maximumUTF8Bytes: 1024))
    }
}
