import Foundation
import XCTest
@testable import RemSoundCore

final class BrowserListenerProfileTests: XCTestCase {
    private func profile() -> ConnectionProfile {
        .init(title:"Browser",displayName:"Test",manualPeerAddress:"",selectedPeerAddresses:[],sendInput:false,receiveAudio:false,allowPlugins:false,reconnectOnOpen:false)
    }
    private func object(_ p: ConnectionProfile) throws -> [String:Any] {try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(p)) as? [String:Any])}
    private func decode(_ value:[String:Any]) throws -> ConnectionProfile {try JSONDecoder().decode(ConnectionProfile.self,from:JSONSerialization.data(withJSONObject:value))}
    func testNewAndLegacyProfileChoicesAreOffWithoutMachineMigration() throws {
        let p=profile();XCTAssertFalse(p.browserListenerEnabled);XCTAssertFalse(p.browserListenerAutoStart)
        var raw=try object(p);raw.removeValue(forKey:"browserListenerEnabled");raw.removeValue(forKey:"browserListenerAutoStart")
        let old=try decode(raw);XCTAssertFalse(old.browserListenerEnabled);XCTAssertFalse(old.browserListenerAutoStart)
    }
    func testEveryBooleanPairRoundTripsAndAffectsDirtyEquality() throws {
        let original=profile()
        for enabled in [false,true] {for auto in [false,true] {var p=original;p.browserListenerEnabled=enabled;p.browserListenerAutoStart=auto
            XCTAssertEqual(try decode(object(p)),p);if enabled || auto {XCTAssertNotEqual(p,original)}
        }}
    }
    func testMalformedKnownBooleanRefusesRatherThanEnablingByCoercion() throws {
        for key in ["browserListenerEnabled","browserListenerAutoStart"] {for value:Any in [1,"true",[],[:]] {
            var raw=try object(profile());raw[key]=value;XCTAssertThrowsError(try decode(raw))
        }}
    }
    func testPartialLegacyObjectDefaultsOnlyItsAbsentChoice() throws {
        var raw=try object(profile());raw["browserListenerEnabled"]=true;raw.removeValue(forKey:"browserListenerAutoStart")
        let p=try decode(raw);XCTAssertTrue(p.browserListenerEnabled);XCTAssertFalse(p.browserListenerAutoStart)
    }
    func testProfileFileRoundTripIncludesOnlyBooleanBrowserValues() throws {
        let root=try IsolatedTestDirectory.make("browser-profile");defer {try? FileManager.default.removeItem(at:root)}
        let store=ProfileStore(directory:root);var p=profile();p.browserListenerEnabled=true;p.browserListenerAutoStart=true;try store.save(p)
        XCTAssertEqual(try store.load(id:p.id),p)
        let raw=try object(p),keys=Set(raw.keys.filter{$0.lowercased().contains("browser")})
        XCTAssertEqual(keys,["browserListenerEnabled","browserListenerAutoStart"]);XCTAssertFalse(raw.keys.contains(where:{$0.lowercased().contains("password")}))
    }
    func testInitializerUsesExplicitBrowserChoicesIndependentlyOfAudioSending() {
        let p=ConnectionProfile(title:"Explicit",displayName:"Test",manualPeerAddress:"",selectedPeerAddresses:[],sendInput:false,receiveAudio:false,allowPlugins:false,reconnectOnOpen:false,browserListenerEnabled:true,browserListenerAutoStart:true)
        XCTAssertTrue(p.browserListenerEnabled);XCTAssertTrue(p.browserListenerAutoStart);XCTAssertFalse(p.sendInput);XCTAssertFalse(p.allowPlugins)
    }
}
