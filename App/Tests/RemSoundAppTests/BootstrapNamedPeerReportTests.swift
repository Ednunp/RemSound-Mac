import Foundation
import XCTest
import RemSoundRuntime
@testable import RemSoundApp

final class BootstrapNamedPeerReportTests: XCTestCase {
    func root() throws -> URL {
        let base=try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"]),root=URL(fileURLWithPath:base).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);addTeardownBlock{try? FileManager.default.removeItem(at:root)};return root
    }
    func testActualHistoryReportReadsOnlyGlobalBookAndLeavesSettingsExact() throws {
        let root=try root(),file=root.appendingPathComponent("settings.plist"),store=try SettingsStore(file:file)
        XCTAssertTrue(store.setValues(["password":"secret fixture","peerAliases":["192.0.2.9":"profile-only alias"]]))
        let book=try NamedPeerHistory(settings:store)
        XCTAssertTrue(book.name(machine:"Studio",address:"192.0.2.1",friendlyName:"Alpha",at:Date(timeIntervalSince1970:1700000000)))
        XCTAssertTrue(book.name(machine:"Desk",address:nil,friendlyName:"Zulu"))
        let raw=try Data(contentsOf:file),options=try LaunchOptions.parse(["--named-peers","--config-dir",root.path])
        let out=try XCTUnwrap(BootstrapReports.output(for:options,profileTitles:{_ in XCTFail("profiles queried");return []},defaultProfiles:{XCTFail("normal default queried");return root},nativeDevices:{XCTFail("device queried");return .init(inputs:[],outputs:[])}))
        XCTAssertTrue(out.hasPrefix("Named peers (2):"));XCTAssertTrue(out.contains("Alpha  (Studio)"));XCTAssertTrue(out.contains("last seen"));XCTAssertTrue(out.contains("192.0.2.1"));XCTAssertTrue(out.contains("Zulu  (Desk)  - not seen yet"))
        XCTAssertFalse(out.contains("secret"));XCTAssertFalse(out.contains("profile-only"));XCTAssertEqual(try Data(contentsOf:file),raw)
    }
    func testMissingIsolatedHistoryHasNoNormalFallbackOrDirectoryCreation() throws {
        let root=try root().appendingPathComponent("absent"),options=try LaunchOptions.parse(["--list-named-peers","--config-dir",root.path])
        XCTAssertEqual(try BootstrapReports.output(for:options),"No named peers.\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.path))
    }
    func testUnreadableHistoryFailsRatherThanReportingEmptyOrRepairing() throws {
        let root=try root(),file=root.appendingPathComponent("settings.plist")
        try Data("private malformed fixture".utf8).write(to:file);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        let before=try Data(contentsOf:file)
        XCTAssertThrowsError(try BootstrapReports.output(for:LaunchOptions.parse(["--named-peers","--config-dir",root.path])))
        XCTAssertEqual(try Data(contentsOf:file),before)
    }
    func testInjectedOversizeReportRefusesInsteadOfPrintingPartialSuccess() throws {
        let root=try root(),book=try NamedPeerHistory(settings:SettingsStore(file:root.appendingPathComponent("settings.plist")))
        XCTAssertTrue(book.name(machine:"Studio",address:nil,friendlyName:"My room"))
        let row=try XCTUnwrap(book.entries.first)
        XCTAssertThrowsError(try BootstrapReports.output(for:LaunchOptions.parse(["--named-peers"]),namedPeers:{_ in Array(repeating:row,count:513)}))
        let data=try JSONSerialization.data(withJSONObject:["machineName":String(repeating:"🧪",count:160),"friendlyName":String(repeating:"🧪",count:80)])
        let wide=try JSONDecoder().decode(NamedPeerRecord.self,from:data)
        XCTAssertThrowsError(try BootstrapReports.output(for:LaunchOptions.parse(["--named-peers"]),namedPeers:{_ in Array(repeating:wide,count:512)}))

    }

}
