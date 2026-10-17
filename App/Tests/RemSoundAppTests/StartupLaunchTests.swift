import XCTest
import RemSoundRuntime
@testable import RemSoundApp
import RemSoundCore

@MainActor final class StartupLaunchTests: XCTestCase {
    private func profile(_ title:String, peers:[String] = []) -> ConnectionProfile {
        .init(title:title,displayName:"Fixture",manualPeerAddress:"",selectedPeerAddresses:peers,
            sendInput:false,receiveAudio:false,allowPlugins:false,reconnectOnOpen:false)
    }
    func testAuthorizedAccessibilityCheckKeepsItsVisibleSurfaceDespiteCueSilence() throws {
        let check = try LaunchOptions.parse(["--check-accessibility","--silent","--config-dir","/private-fixture"],
            environment:["REMSOUND_ALLOW_VISIBLE_UI_TESTS":"1"])
        XCTAssertFalse(AppRuntime.hidesStartupWindow(check))
        XCTAssertTrue(AppRuntime.hidesStartupWindow(try LaunchOptions.parse(["--silent"])))
        XCTAssertTrue(AppRuntime.hidesStartupWindow(try LaunchOptions.parse(["--tray"])))
        XCTAssertFalse(AppRuntime.hidesStartupWindow(try LaunchOptions.parse([])))
    }
    func testParserPreservesProfileCaseAndAllMinimizedAliases() throws {
        for alias in ["--minimized","--minimised","--tray"] {
            let o = try LaunchOptions.parse(["--profile","Studio One",alias])
            XCTAssertEqual(o.startup.profileName,"Studio One");XCTAssertTrue(o.startup.startMinimized)
        }
    }
    func testRepeatedNumericPeersCanonicalizeWithoutDNSAndDefaultPortIsOmitted() throws {
        let o = try LaunchOptions.parse(["--connect","127.000.0.1:47830","--connect","127.0.0.2:47300"])
        XCTAssertEqual(o.startup.connectPeers,["127.0.0.1","127.0.0.2:47300"])
        XCTAssertEqual(try LaunchOptions.parse(["--connect","127.0.0.1:\(Wire.audioPort)"]).startup.connectPeers,["127.0.0.1"])
    }
    func testInvalidMissingAndConflictingStartupArgumentsFailClosed() {
        for args in [["--profile"],["--profile",""],["--profile","a","--profile","b"],
            ["--connect"],["--connect","example.invalid"],["--connect","::1"],
            ["--connect","127.0.0.1:0"],["--connect","127.0.0.1:65536"],
            ["--connect","256.0.0.1"],["--profile","one\ntwo"],
            ["--version","--tray"],["--profiles","--connect","127.0.0.1"],
            ["--config-dir","/private-fixture","--control","status","--profile","a"]] {
            XCTAssertThrowsError(try LaunchOptions.parse(args),"\(args)")
        }
    }
    func testStartupBoundsRejectUnboundedProfileOrPeerLists() {
        XCTAssertThrowsError(try LaunchOptions.parse(["--profile",String(repeating:"a",count:513)]))
        XCTAssertThrowsError(try LaunchOptions.parse(Array(repeating:["--connect","127.0.0.1"],count:65).flatMap{$0}))
    }
    func testHeadlessStillRequiresIsolationAndReportsRemainEarly() throws {
        XCTAssertThrowsError(try LaunchOptions.parse(["--headless","--profile","a"]))
        let o = try LaunchOptions.parse(["--headless","--silent","--config-dir","/private-fixture","--profile","a"])
        XCTAssertEqual(o.startup.profileName,"a");XCTAssertTrue(o.headless)
        XCTAssertEqual(try LaunchOptions.parse(["--version"]).report,.version)
    }
    func testExplicitProfileWinsAndPeerEditsAreWorkingCopyOnly() throws {
        let p=profile("Studio",peers:["127.0.0.2"]),before=p
        var o=StartupOptions();o.profileName="Studio";o.connectPeers=["127.0.0.2","127.0.0.3:47000"]
        let plan=try StartupLaunchPlan.make(o,profiles:{[p]})
        XCTAssertEqual(plan.profile?.id,p.id);XCTAssertEqual(plan.selectedPeers,["127.0.0.2","127.0.0.3:47000"])
        XCTAssertTrue(plan.startRequested);XCTAssertFalse(plan.blank);XCTAssertEqual(p,before)
    }
    func testConnectWithoutProfileUsesBlankAndNeverEnumeratesStoredProfiles() throws {
        var o=StartupOptions();o.connectPeers=["127.0.0.2","127.0.0.2"]
        let plan=try StartupLaunchPlan.make(o,profiles:{XCTFail("Unrequested profile read");return []})
        XCTAssertTrue(plan.blank);XCTAssertNil(plan.profile);XCTAssertEqual(plan.selectedPeers,["127.0.0.2"])
    }
    func testNoOverridesLeavesNormalRestoreAndDoesNotReadProfiles() throws {
        let plan=try StartupLaunchPlan.make(.init(),profiles:{XCTFail("Unrequested profile read");return []})
        XCTAssertFalse(plan.overridesProfile);XCTAssertFalse(plan.startRequested)
    }
    func testMissingAndAmbiguousProfileDoNotFallBackOrChooseArbitrarily() throws {
        var o=StartupOptions();o.profileName="Missing"
        XCTAssertThrowsError(try StartupLaunchPlan.make(o,profiles:{[profile("Studio")]}))
        o.profileName="studio"
        XCTAssertThrowsError(try StartupLaunchPlan.make(o,profiles:{[profile("Studio"),profile("STUDIO")]}))
        o.profileName="Studio"
        XCTAssertEqual(try StartupLaunchPlan.make(o,profiles:{[profile("Studio"),profile("STUDIO")]}).profile?.title,"Studio")
    }
    func testProfileReconnectChoiceOnlyStartsWhenRequested() throws {
        var o=StartupOptions();o.profileName="Studio";var p=profile("Studio")
        XCTAssertFalse(try StartupLaunchPlan.make(o,profiles:{[p]}).startRequested)
        p.reconnectOnOpen=true;XCTAssertTrue(try StartupLaunchPlan.make(o,profiles:{[p]}).startRequested)
    }
    func testExistingSelectedPeersDoNotOverrideProfileReconnectOff() throws {
        var o=StartupOptions();o.profileName="Studio"
        let p=profile("Studio",peers:["127.0.0.2"])
        XCTAssertFalse(try StartupLaunchPlan.make(o,profiles:{[p]}).startRequested)
    }
    func testProfileOptionCannotConsumeAnotherFlagOrLineSeparator() {
        XCTAssertThrowsError(try LaunchOptions.parse(["--profile","-v"]))
        XCTAssertThrowsError(try LaunchOptions.parse(["--profile","one\u{2028}two"]))
    }
    func testRequestOwnerRejectsOldConsumedStoppedAndClosedCallbacks() {
        let owner=StartupRequestOwner();let old=owner.begin(),new=owner.begin()
        XCTAssertFalse(owner.consume(old));XCTAssertTrue(owner.consume(new));XCTAssertFalse(owner.consume(new))
        let stopped=owner.begin();owner.invalidate();XCTAssertFalse(owner.consume(stopped))
        let closed=owner.begin();owner.shutdown();XCTAssertFalse(owner.consume(closed));XCTAssertFalse(owner.consume(owner.begin()))
    }
}
