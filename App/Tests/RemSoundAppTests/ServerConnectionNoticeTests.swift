import Foundation
import RemSoundRuntime
import XCTest
@testable import RemSoundApp

@MainActor
final class ServerConnectionNoticeTests: XCTestCase {
    @MainActor private final class Dialog: ServerNoticePresentation {
        let answer: (Bool)->Void
        var shows = 0, retirements = 0, errors:[String] = [], retireHook:(()->Void)?
        init(_ answer:@escaping(Bool)->Void) { self.answer = answer }
        func present() { shows += 1 }
        func retire() { retirements += 1;retireHook?() }
        func showError(_ message:String) { errors.append(message) }
    }
    @MainActor private final class Fixture {
        let configuration: RuntimeConfiguration
        var unattended = false, allowed = true, logs:[String] = [], dialogs:[Dialog] = [], connected = 0
        var factoryHook:((Dialog)->Void)?
        var owner:ServerConnectionNotice!
        init() throws {
            let path = ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"]! + "/notice-" + UUID().uuidString
            configuration = try .init(options:.parse(["--config-dir",path,"--silent","--headless"]))
            owner = .init(settings:configuration.settings,unattended:{ self.unattended },allowed:{ self.allowed },log:{ self.logs.append($0) },
                makeDialog:{ let d = Dialog($0);self.dialogs.append(d);self.factoryHook?(d);return d })
        }
        func begin() { owner.begin { self.connected += 1 } }
    }
    private func fixture() throws -> Fixture {
        let f = try Fixture(); addTeardownBlock { MainActor.assumeIsolated { f.owner.shutdown() } };return f
    }
    func testUnattendedLogsAndContinuesWithoutFactoryOrPreferenceWrite() throws {
        let f = try fixture();f.unattended = true;f.begin();f.begin()
        XCTAssertEqual(f.connected,2);XCTAssertTrue(f.dialogs.isEmpty);XCTAssertEqual(f.logs.count,2)
        XCTAssertTrue(f.logs.allSatisfy{ $0.contains("same password") });XCTAssertNil(f.configuration.settings.object(forKey:ServerConnectionNotice.settingsKey))
    }
    func testIsolationRefusesPresentationBeforeFactoryButKeepsCommonConnectionCaller() throws {
        let f = try fixture();f.allowed = false;f.begin();XCTAssertEqual(f.connected,1);XCTAssertTrue(f.dialogs.isEmpty)
        XCTAssertNil(f.configuration.settings.object(forKey:ServerConnectionNotice.settingsKey))
    }
    func testSavedSuppressionDoesNotConstructUIOrRewriteChoice() throws {
        let f = try fixture();f.configuration.settings.set(true,forKey:ServerConnectionNotice.settingsKey)
        let file=f.configuration.root!.appendingPathComponent("settings.plist"),before=try Data(contentsOf:file);f.begin()
        XCTAssertEqual(f.connected,1);XCTAssertTrue(f.dialogs.isEmpty);XCTAssertEqual(try Data(contentsOf:file),before)
    }
    func testInteractiveNoticeWaitsForAnswerThenRetiresBeforeConnection() throws {
        let f=try fixture();f.begin();let d=try XCTUnwrap(f.dialogs.first);XCTAssertEqual(d.shows,1);XCTAssertEqual(f.connected,0)
        d.answer(false);XCTAssertEqual(d.retirements,1);XCTAssertEqual(f.connected,1);XCTAssertNil(f.configuration.settings.object(forKey:ServerConnectionNotice.settingsKey))
        d.answer(true);XCTAssertEqual(f.connected,1);XCTAssertNil(f.configuration.settings.object(forKey:ServerConnectionNotice.settingsKey))
    }
    func testExplicitSuppressionWritesOnlyCurrentChoiceAndPreservesConcurrentSettings() throws {
        let f=try fixture();f.configuration.settings.set("old",forKey:"profileMarker");f.begin();let d=try XCTUnwrap(f.dialogs.first)
        f.configuration.settings.set("new",forKey:"profileMarker");d.answer(true)
        XCTAssertTrue(f.configuration.settings.bool(forKey:ServerConnectionNotice.settingsKey));XCTAssertEqual(f.configuration.settings.string(forKey:"profileMarker"),"new")
        XCTAssertEqual(f.connected,1);f.begin();XCTAssertEqual(f.connected,2);XCTAssertEqual(f.dialogs.count,1)
    }
    func testFailedSuppressionSaveKeepsNoticeReadableAndRetryableWithoutConnecting() throws {
        let f=try fixture();f.begin();let d=try XCTUnwrap(f.dialogs.first),root=f.configuration.root!
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:root.path);defer{try? FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:root.path)}
        d.answer(true);XCTAssertEqual(f.connected,0);XCTAssertEqual(d.errors.count,1);XCTAssertEqual(d.retirements,0)
        XCTAssertFalse(f.configuration.settings.bool(forKey:ServerConnectionNotice.settingsKey))
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:root.path);d.answer(true)
        XCTAssertEqual(f.connected,1);XCTAssertEqual(d.retirements,1);XCTAssertTrue(f.configuration.settings.bool(forKey:ServerConnectionNotice.settingsKey))
    }
    func testReplacementAndShutdownRefuseOldResponsesBeforeConnect() throws {
        let f=try fixture();f.begin();let old=try XCTUnwrap(f.dialogs.first);f.begin();let newest=try XCTUnwrap(f.dialogs.last)
        XCTAssertEqual(old.retirements,1);old.answer(true);XCTAssertEqual(f.connected,0);XCTAssertNil(f.configuration.settings.object(forKey:ServerConnectionNotice.settingsKey))
        f.owner.shutdown();XCTAssertEqual(newest.retirements,1);newest.answer(true);f.begin();XCTAssertEqual(f.connected,0);XCTAssertEqual(f.dialogs.count,2)
    }
    func testStopInvalidatesOnlyCurrentNoticeWithoutPermanentlyClosingOwner() throws {
        let f=try fixture();f.begin();let d=try XCTUnwrap(f.dialogs.first);f.owner.invalidate();d.answer(false);XCTAssertEqual(f.connected,0)
        f.unattended=true;f.begin();XCTAssertEqual(f.connected,1);XCTAssertEqual(d.retirements,1)
    }
    func testSynchronousFactoryAnswerWaitsResourceReturnAndRetirement() throws {
        let f=try fixture();f.factoryHook={d in d.answer(false);XCTAssertEqual(f.connected,0)};f.begin()
        let d=try XCTUnwrap(f.dialogs.first);XCTAssertEqual(d.retirements,1);XCTAssertEqual(d.shows,0);XCTAssertEqual(f.connected,1)
    }
    func testShutdownDuringFactoryRetiresReturnedResourceWithoutPresentingOrConnecting() throws {
        let f=try fixture();f.factoryHook={_ in f.owner.shutdown()};f.begin();let d=try XCTUnwrap(f.dialogs.first)
        XCTAssertEqual(d.shows,0);XCTAssertEqual(d.retirements,1);d.answer(true);XCTAssertEqual(f.connected,0)
    }
    func testStopDuringResourceRetirementPreventsQueuedConnection() throws {
        let f=try fixture();f.begin();let d=try XCTUnwrap(f.dialogs.first);d.retireHook={f.owner.invalidate()};d.answer(false)
        XCTAssertEqual(f.connected,0);XCTAssertEqual(d.retirements,1)
    }
    func testNewRequestDuringResourceRetirementWinsOverOldCompletion() throws {
        let f=try fixture();f.begin();let d=try XCTUnwrap(f.dialogs.first)
        d.retireHook={f.unattended=true;f.begin()};d.answer(false)
        XCTAssertEqual(f.connected,1);XCTAssertEqual(d.retirements,1)
    }
    func testDuplicateFactoryRepliesUseFirstDecisionAndOneConnect() throws {
        let f=try fixture();f.factoryHook={d in d.answer(true);d.answer(false)};f.begin()
        XCTAssertTrue(f.configuration.settings.bool(forKey:ServerConnectionNotice.settingsKey));XCTAssertEqual(f.connected,1)
        XCTAssertEqual(f.dialogs.first?.retirements,1);XCTAssertEqual(f.dialogs.first?.shows,0)
    }
}
