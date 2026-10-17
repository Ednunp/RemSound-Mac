import XCTest
import Security
@testable import RemSoundCore

final class PasswordStoreTests: XCTestCase {
    func testEphemeralPasswordsAreSeparateAndNeverPersistBetweenInstances() throws {
        let first = PasswordStore(ephemeral: true)
        let second = PasswordStore(ephemeral: true)
        XCTAssertNil(try first.load())
        try first.save("temporary test value")
        XCTAssertEqual(try first.load(), "temporary test value")
        XCTAssertNil(try second.load())
        try first.save("replacement")
        XCTAssertEqual(try first.load(), "replacement")
        try first.delete()
        XCTAssertNil(try first.load())
        XCTAssertNil(try PasswordStore(ephemeral: true).load())
    }

    func testKeychainPasswordLifecycle() throws {
        guard ProcessInfo.processInfo.environment["REMSOUND_ALLOW_KEYCHAIN_TESTS"] == "1" else {
            throw XCTSkip("Real Keychain integration requires REMSOUND_ALLOW_KEYCHAIN_TESTS=1 in an agreed test window.")
        }
        let store = PasswordStore(service: "org.remsound.mac.test", account: UUID().uuidString)
        let anotherProfile = PasswordStore(service: "org.remsound.mac.test", account: UUID().uuidString)
        defer { try? store.delete() }
        defer { try? anotherProfile.delete() }
        XCTAssertNil(try store.load())
        do {
            try store.save("first test password")
        } catch let error as PasswordStoreError where error.status == errSecInteractionNotAllowed
            && ProcessInfo.processInfo.environment["SSH_CONNECTION"] != nil {
            throw XCTSkip("SSH cannot access the login Keychain; rerun this test in the GUI session.")
        }
        XCTAssertEqual(try store.load(), "first test password")
        try store.save("replacement test password")
        XCTAssertEqual(try store.load(), "replacement test password")
        try anotherProfile.save("another profile password")
        XCTAssertEqual(try anotherProfile.load(), "another profile password")
        try store.delete()
        XCTAssertNil(try store.load())
        XCTAssertEqual(try anotherProfile.load(), "another profile password")
    }
}
