import Foundation
import RemSoundCore
import XCTest
@testable import RemSoundApp

final class ProfilePasswordStoresTests: XCTestCase {
    func testBrowserServiceRoleIsSeparateAndAudioIdentityUnchanged() {
        XCTAssertEqual(ProfilePasswordStores.service(for: .audio), "org.remsound.mac.shared-password")
        XCTAssertEqual(ProfilePasswordStores.service(for: .browser), "org.remsound.mac.browser-listener-password")
    }
    func testEqualAccountNeverBorrowsAudioPassword() throws {
        let owner = ProfilePasswordStores(), account = UUID().uuidString
        let audio = owner.store(account: account, isolated: true), browser = owner.store(account: account, role: .browser, isolated: true)
        try audio.save("synthetic audio"); XCTAssertNil(try browser.load()); XCTAssertFalse(audio === browser)
        try browser.save("synthetic browser"); XCTAssertEqual(try audio.load(), "synthetic audio"); XCTAssertEqual(try browser.load(), "synthetic browser")
    }
    func testSameRoleAndProfileReusesOnlyItsMemoryStore() throws {
        let owner = ProfilePasswordStores(), account = UUID().uuidString
        let first = owner.store(account: account, role: .browser, isolated: true); try first.save("synthetic")
        let again = owner.store(account: account, role: .browser, isolated: true)
        XCTAssertTrue(first === again); XCTAssertEqual(try again.load(), "synthetic")
    }
    func testProfilesAndDefaultRoleKeysDoNotCollide() throws {
        let owner = ProfilePasswordStores()
        let first = owner.store(account: "browser:default", isolated: true), second = owner.store(role: .browser, isolated: true)
        try first.save("synthetic first"); XCTAssertNil(try second.load()); XCTAssertFalse(first === second)
        let other = owner.store(account: UUID().uuidString, role: .browser, isolated: true); try other.save("synthetic other")
        XCTAssertNil(try second.load()); XCTAssertEqual(try first.load(), "synthetic first")
    }
    func testDeletingBrowserNeverDeletesAudioOrOtherProfile() throws {
        let owner = ProfilePasswordStores(), account = UUID().uuidString
        let audio = owner.store(account: account, isolated: true), browser = owner.store(account: account, role: .browser, isolated: true), other = owner.store(role: .browser, isolated: true)
        try audio.save("synthetic audio"); try browser.save("synthetic browser"); try other.save("synthetic other"); try browser.delete()
        XCTAssertNil(try browser.load()); XCTAssertEqual(try audio.load(), "synthetic audio"); XCTAssertEqual(try other.load(), "synthetic other")
    }
    func testSeparateRunOwnerNeverMigratesEarlierMemoryCredential() throws {
        let first = ProfilePasswordStores(), second = ProfilePasswordStores()
        try first.store(role: .browser, isolated: true).save("synthetic")
        XCTAssertNil(try second.store(role: .browser, isolated: true).load())
    }
    func testRepeatedBoundedRoleReplacementPreservesExactOtherRole() throws {
        let owner = ProfilePasswordStores(); try owner.store(isolated: true).save("synthetic audio")
        let browser = owner.store(role: .browser, isolated: true)
        for index in 0..<200 { try browser.save("synthetic \(index)"); XCTAssertEqual(try owner.store(role: .browser, isolated: true).load(), "synthetic \(index)") }
        try browser.delete(); XCTAssertEqual(try owner.store(isolated: true).load(), "synthetic audio")
    }
}
