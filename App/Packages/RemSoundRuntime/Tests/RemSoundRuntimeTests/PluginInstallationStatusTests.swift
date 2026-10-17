import Foundation
import Darwin
import XCTest
@testable import RemSoundRuntime

final class PluginInstallationStatusTests: XCTestCase {
    private func root() throws -> URL {
        let base=try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])
        let root=URL(fileURLWithPath:base).appendingPathComponent(UUID().uuidString)
        addTeardownBlock {try? FileManager.default.removeItem(at:root)}
        return root
    }
    @discardableResult private func bundle(_ root:URL,_ index:Int=0,version:String="1.2.3") throws -> URL {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let url=root.appendingPathComponent(PluginInstallationStatus.locations[index].1)
        for folder in ["Contents/MacOS","Contents/Frameworks"] {try FileManager.default.createDirectory(at:url.appendingPathComponent(folder),withIntermediateDirectories:true)}
        let info:[String:Any]=["CFBundleIdentifier":"org.remsound.plugin","CFBundleExecutable":"RemSound","CFBundleShortVersionString":version,"CFBundleVersion":"42","UnrelatedSecret":"never-return-this"]
        try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:url.appendingPathComponent("Contents/Info.plist"))
        let executable=url.appendingPathComponent("Contents/MacOS/RemSound")
        try Data("synthetic metadata only".utf8).write(to:executable)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:executable.path)
        try Data([1]).write(to:url.appendingPathComponent("Contents/Frameworks/libRemSoundPluginHost-v1.dylib"))
        return url
    }
    func testMissingRootIsAReadOnlyFixedThreeSlotSnapshot() throws {
        let root=try root(),report=try RuntimeConfiguration.pluginStatusForListing(root:root)
        XCTAssertEqual(report.items.map(\.format),["AU","VST3","CLAP"])
        XCTAssertTrue(report.items.allSatisfy{$0.state == .missing})
        XCTAssertTrue(report.metadataOnly);XCTAssertEqual(report.scope,"isolated")
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.path))
    }
    func testActualFixedBundleMetadataAndNestedRuntimeAreReportedWithoutLoadingOrWriting() throws {
        let root=try root();for i in 0..<3 {try bundle(root,i)}
        let before=try Data(contentsOf:root.appendingPathComponent(PluginInstallationStatus.locations[0].1+"/Contents/Info.plist"))
        let report=try RuntimeConfiguration.pluginStatusForListing(root:root)
        XCTAssertTrue(report.items.allSatisfy{$0.state == .metadataPresent && $0.version == "1.2.3" && $0.build == "42" && $0.executablePresent == true && $0.sharedRuntimePresent == true})
        let json=try JSONEncoder().encode(report),text=String(decoding:json,as:UTF8.self)
        XCTAssertFalse(text.contains(root.path));XCTAssertFalse(text.contains("never-return-this"));XCTAssertFalse(text.contains("UnrelatedSecret"))
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(PluginInstallationStatus.locations[0].1+"/Contents/Info.plist")),before)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("settings.plist").path))
    }
    func testMissingPayloadIsIncompleteNotAValidInstallClaim() throws {
        let root=try root(),url=try bundle(root)
        try FileManager.default.removeItem(at:url.appendingPathComponent("Contents/Frameworks/libRemSoundPluginHost-v1.dylib"))
        let row=try XCTUnwrap(RuntimeConfiguration.pluginStatusForListing(root:root).items.first)
        XCTAssertEqual(row.state,.incomplete);XCTAssertEqual(row.executablePresent,true);XCTAssertEqual(row.sharedRuntimePresent,false)
    }
    func testWrongIdentityArbitraryExecutableAndTerminalVersionAreInvalidAndNotReturned() throws {
        let root=try root(),url=try bundle(root),info=url.appendingPathComponent("Contents/Info.plist")
        for pair in [("CFBundleIdentifier","other.vendor"),("CFBundleExecutable","../../foreign"),("CFBundleShortVersionString","1.2.3\nSECRET")] {
            try bundle(root)
            var object=try PropertyListSerialization.propertyList(from:Data(contentsOf:info),format:nil) as! [String:Any]
            object[pair.0]=pair.1;try PropertyListSerialization.data(fromPropertyList:object,format:.xml,options:0).write(to:info)
            let report=try RuntimeConfiguration.pluginStatusForListing(root:root)
            XCTAssertEqual(report.items[0].state,.invalid)
            XCTAssertNil(report.items[0].version)
            XCTAssertFalse(String(decoding:try JSONEncoder().encode(report),as:UTF8.self).contains("SECRET"))
        }
    }
    func testRedirectedRootNeverReadsOrCreatesOutsideIt() throws {
        let root=try root(),outside=try self.root();try bundle(outside)
        try FileManager.default.createSymbolicLink(at:root,withDestinationURL:outside)
        XCTAssertThrowsError(try RuntimeConfiguration.pluginStatusForListing(root:root))
    }
    func testRedirectedBundleIsUnavailableWithoutFollowingIt() throws {
        let root=try root(),outside=try self.root(),url=try bundle(root)
        try bundle(outside);try FileManager.default.removeItem(at:url)
        try FileManager.default.createSymbolicLink(at:url,withDestinationURL:outside.appendingPathComponent(PluginInstallationStatus.locations[0].1))
        XCTAssertEqual(try RuntimeConfiguration.pluginStatusForListing(root:root).items[0].state,.unavailable)
    }
    func testChangedBundleReceiptCannotReturnOldMetadataAsCurrent() throws {
        let root=try root(),url=try bundle(root)
        let report=try PluginInstallationStatus.read(base:root,isolated:true,beforeFinal:{
            try FileManager.default.moveItem(at:url,to:url.appendingPathExtension("old"))
        })
        XCTAssertTrue(report.items.allSatisfy{$0.state == .unavailable})
    }
    func testFIFOInfoIsRefusedWithoutOpeningOrBlockingOnItsWriter() throws {
        let root=try root(),url=try bundle(root),info=url.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.removeItem(at:info)
        XCTAssertEqual(mkfifo(info.path,0o600),0)
        let start=ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(try RuntimeConfiguration.pluginStatusForListing(root:root).items[0].state,.unavailable)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-start,1)
    }
    func testOversizedAndRedirectedInfoAreUnavailableAndNeverChangedOrReturned() throws {
        let root=try root(),url=try bundle(root),info=url.appendingPathComponent("Contents/Info.plist")
        let large=Data(repeating:65,count:128*1024+1);try large.write(to:info)
        XCTAssertEqual(try RuntimeConfiguration.pluginStatusForListing(root:root).items[0].state,.unavailable)
        XCTAssertEqual(try Data(contentsOf:info),large)
        let outside=root.appendingPathComponent("unrelated-secret");try Data("never disclose this".utf8).write(to:outside)
        try FileManager.default.removeItem(at:info);try FileManager.default.createSymbolicLink(at:info,withDestinationURL:outside)
        let report=try RuntimeConfiguration.pluginStatusForListing(root:root)
        XCTAssertEqual(report.items[0].state,.unavailable)
        XCTAssertFalse(String(decoding:try JSONEncoder().encode(report),as:UTF8.self).contains("never disclose"))
    }
    func testPublicIsolatedRootIsRefusedWithoutReadingItsPayload() throws {
        let root=try root();try bundle(root)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:root.path)
        XCTAssertThrowsError(try RuntimeConfiguration.pluginStatusForListing(root:root))
    }
}
