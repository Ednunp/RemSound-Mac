import Foundation
import XCTest
@testable import RemSoundRuntime

final class NamedPeerHistoryTests: XCTestCase {
    func root() throws -> URL {
        let base=try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])
        let root=URL(fileURLWithPath:base).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        addTeardownBlock {try? FileManager.default.removeItem(at:root)};return root
    }
    func testExplicitNameAndClearRoundTripRealStoreWithoutAliasMigration() throws {
        let root=try root(),file=root.appendingPathComponent("settings.plist"),store=try SettingsStore(file:file)
        XCTAssertTrue(store.setValues(["peerAliases":["192.0.2.9":"profile only"],"rememberedPeerBook":["entries":["remembered"],"migrated":true]]))
        let book=try NamedPeerHistory(settings:store)
        XCTAssertTrue(book.entries.isEmpty);XCTAssertTrue(try RuntimeConfiguration.namedPeersForListing(root:root).isEmpty)
        XCTAssertTrue(book.name(machine:"STUDIO",address:nil,friendlyName:"My studio"))
        let rows=try RuntimeConfiguration.namedPeersForListing(root:root)
        XCTAssertEqual(rows.count,1);XCTAssertEqual(rows.first?.friendlyName,"My studio");XCTAssertNil(rows.first?.lastSeen)
        XCTAssertTrue(book.name(machine:"studio",address:nil,friendlyName:""))
        XCTAssertTrue(try RuntimeConfiguration.namedPeersForListing(root:root).isEmpty)
        XCTAssertEqual(try SettingsStore(file:file).dictionary(forKey:"peerAliases")?["192.0.2.9"] as? String,"profile only")
    }
    func testConnectedOnlyUpdatesPreviouslyNamedAndFlushesTimestampAtOwnerBoundary() throws {
        let root=try root(),file=root.appendingPathComponent("settings.plist"),store=try SettingsStore(file:file)
        let book=try NamedPeerHistory(settings:store),date=Date(timeIntervalSince1970:1700000000)
        XCTAssertFalse(book.noteConnected(machine:"unnamed",address:"192.0.2.1",at:date))
        XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
        XCTAssertTrue(book.name(machine:"Studio",address:"192.0.2.1",friendlyName:"My room",at:date))
        let before=try Data(contentsOf:file)
        XCTAssertTrue(book.noteConnected(machine:"STUDIO",address:"192.0.2.1",at:date.addingTimeInterval(5)))
        XCTAssertEqual(try Data(contentsOf:file),before)
        XCTAssertTrue(book.flush());XCTAssertEqual(try RuntimeConfiguration.namedPeersForListing(root:root).first?.lastSeen,date.addingTimeInterval(5))
        XCTAssertTrue(book.noteConnected(machine:"Studio",address:"192.0.2.2",at:date.addingTimeInterval(10)))
        XCTAssertEqual(try RuntimeConfiguration.namedPeersForListing(root:root).first?.lastAddress,"192.0.2.2")
        XCTAssertFalse(book.noteConnected(machine:"Studio",address:"192.0.2.3",at:date));XCTAssertEqual(book.entries.first?.lastAddress,"192.0.2.2")
    }
    func testFailedWritePreservesPriorBookAndDoesNotFallback() throws {
        let root=try root(),file=root.appendingPathComponent("settings.plist"),store=try SettingsStore(file:file),book=try NamedPeerHistory(settings:store)
        XCTAssertTrue(book.name(machine:"Studio",address:nil,friendlyName:"Before"))
        try FileManager.default.removeItem(at:file);try FileManager.default.createDirectory(at:file,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        XCTAssertFalse(book.name(machine:"Studio",address:nil,friendlyName:"After"))
        XCTAssertEqual(book.entries.first?.friendlyName,"Before");XCTAssertTrue(store.persistenceFailed)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:file.path).isEmpty)
    }
    func testMissingReadOnlyRootsStayMissingAndUnrelatedDataIsNotReported() throws {
        let root=try root(),missing=root.appendingPathComponent("missing"),file=root.appendingPathComponent("settings.plist")
        XCTAssertTrue(try RuntimeConfiguration.namedPeersForListing(root:missing).isEmpty);XCTAssertFalse(FileManager.default.fileExists(atPath:missing.path))
        XCTAssertTrue(try RuntimeConfiguration.namedPeersForListing(root:root).isEmpty);XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
        let store=try SettingsStore(file:file);XCTAssertTrue(store.setValues(["password":"secret fixture","peerAliases":["192.0.2.1":"not history"]]))
        let raw=try Data(contentsOf:file);XCTAssertTrue(try RuntimeConfiguration.namedPeersForListing(root:root).isEmpty)
        XCTAssertEqual(try Data(contentsOf:file),raw)
    }
    func testMalformedAndDuplicateHistoryRefusesWithoutRepairOrPartialSuccess() throws {
        let root=try root(),file=root.appendingPathComponent("settings.plist"),store=try SettingsStore(file:file)
        for value:Any in ["wrong type",Data("not JSON".utf8),Data(repeating:0,count:256*1024+1)] {
            XCTAssertTrue(store.setValues(["namedPeerHistory":value]));let raw=try Data(contentsOf:file)
            XCTAssertThrowsError(try RuntimeConfiguration.namedPeersForListing(root:root));XCTAssertEqual(try Data(contentsOf:file),raw)
        }
        XCTAssertTrue(store.setValues(["namedPeerHistory":nil]));let book=try NamedPeerHistory(settings:store)
        XCTAssertFalse(book.name(machine:"bad\nname",address:nil,friendlyName:"No"))
        XCTAssertFalse(book.name(machine:"Studio",address:"192.0.2.1:123",friendlyName:"No"))
        XCTAssertFalse(book.name(machine:"Studio",address:nil,friendlyName:String(repeating:"x",count:81)))
        XCTAssertTrue(book.name(machine:"Studio",address:nil,friendlyName:"yes"))
        let data=try XCTUnwrap(store.data(forKey:"namedPeerHistory"));var rows=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [[String:Any]])
        var duplicate=rows[0];duplicate["machineName"]="STUDIO";rows.append(duplicate)
        XCTAssertTrue(store.setValues(["namedPeerHistory":try JSONSerialization.data(withJSONObject:rows)]))
        XCTAssertThrowsError(try RuntimeConfiguration.namedPeersForListing(root:root))
    }
    func testReadOnlyFileRefusesSymlinkOversizeAndPermissionsBeforeSettingsDecode() throws {
        let root=try root(),file=root.appendingPathComponent("settings.plist"),target=root.appendingPathComponent("target")
        try Data("private".utf8).write(to:target);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:target.path)
        try FileManager.default.createSymbolicLink(at:file,withDestinationURL:target)
        XCTAssertThrowsError(try RuntimeConfiguration.namedPeersForListing(root:root));try FileManager.default.removeItem(at:file)
        FileManager.default.createFile(atPath:file.path,contents:nil,attributes:[.posixPermissions:0o600]);let handle=try FileHandle(forWritingTo:file)
        try handle.truncate(atOffset:4*1024*1024+1);try handle.close()
        XCTAssertThrowsError(try RuntimeConfiguration.namedPeersForListing(root:root))
        try FileManager.default.removeItem(at:file);let store=try SettingsStore(file:file);XCTAssertTrue(store.setValues(["unrelated":true]))
        try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath:file.path)
        XCTAssertThrowsError(try RuntimeConfiguration.namedPeersForListing(root:root))
    }
    func testPrivateDescriptorModeReproofRetiresChangedRead() throws {
        let file=try root().appendingPathComponent("private.bin");try Data([1,2,3]).write(to:file)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        XCTAssertThrowsError(try StableRegularFile.read(file,maximumBytes:32,privateFile:true,beforeFinal:{
            try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath:file.path)
        }))
    }
    func testRecordCountCapRefusesNewEntryButAllowsAnExistingExplicitRename() throws {
        let root=try root(),file=root.appendingPathComponent("settings.plist"),store=try SettingsStore(file:file)
        let rows=(0..<512).map { ["machineName":"machine-\($0)","friendlyName":"name-\($0)"] }
        XCTAssertTrue(store.setValues(["namedPeerHistory":try JSONSerialization.data(withJSONObject:rows)]))
        let book=try NamedPeerHistory(settings:store),before=try Data(contentsOf:file)
        XCTAssertEqual(book.entries.count,512);XCTAssertFalse(book.name(machine:"extra",address:nil,friendlyName:"No"))
        XCTAssertEqual(try Data(contentsOf:file),before)
        XCTAssertTrue(book.name(machine:"machine-0",address:nil,friendlyName:"Yes"))
        XCTAssertEqual(try RuntimeConfiguration.namedPeersForListing(root:root).count,512)
        XCTAssertTrue(store.setValues(["namedPeerHistory":try JSONSerialization.data(withJSONObject:rows+[["machineName":"extra","friendlyName":"No"]])]))
        XCTAssertThrowsError(try RuntimeConfiguration.namedPeersForListing(root:root))
    }

    func testManagementRenamePreservesObservationAndRejectsStaleRows() throws {
        let root=try root(),store=try SettingsStore(file:root.appendingPathComponent("settings.plist")),book=try NamedPeerHistory(settings:store)
        let date=Date(timeIntervalSince1970:1700000000)
        XCTAssertTrue(book.name(machine:"Studio",address:"192.0.2.1",friendlyName:"Before",at:date))
        let old=try XCTUnwrap(book.entries.first)
        XCTAssertTrue(book.rename(old,friendlyName:"After"))
        XCTAssertEqual(book.entries.first?.lastSeen,date)
        XCTAssertEqual(book.entries.first?.lastAddress,"192.0.2.1")
        XCTAssertFalse(book.rename(old,friendlyName:"Stale"))
        XCTAssertFalse(book.forget([old]))
        XCTAssertEqual(book.entries.first?.friendlyName,"After")
    }
    func testManagementBatchDeleteIsAtomicAndFailedSaveKeepsNames() throws {
        let root=try root(),file=root.appendingPathComponent("settings.plist"),store=try SettingsStore(file:file),book=try NamedPeerHistory(settings:store)
        XCTAssertTrue(book.name(machine:"A",address:nil,friendlyName:"One"))
        XCTAssertTrue(book.name(machine:"B",address:nil,friendlyName:"Two"))
        let rows=book.entries
        try FileManager.default.removeItem(at:file)
        try FileManager.default.createDirectory(at:file,withIntermediateDirectories:false)
        XCTAssertFalse(book.forget(rows));XCTAssertEqual(book.entries,rows)
        try FileManager.default.removeItem(at:file)
        XCTAssertTrue(book.forget(rows));XCTAssertTrue(book.entries.isEmpty)
        XCTAssertFalse(book.noteConnected(machine:"A",address:"192.0.2.1"))
        XCTAssertTrue(try RuntimeConfiguration.namedPeersForListing(root:root).isEmpty)
    }

    func testManagementAllowsHealthyObservationChurnWithoutLosingNewAddressOrTime() throws {
        let root=try root(),store=try SettingsStore(file:root.appendingPathComponent("settings.plist")),book=try NamedPeerHistory(settings:store)
        let before=Date(timeIntervalSince1970:1700000000),after=before.addingTimeInterval(5)
        XCTAssertTrue(book.name(machine:"Studio",address:"192.0.2.1",friendlyName:"Before",at:before))
        let shown=try XCTUnwrap(book.entries.first)
        XCTAssertTrue(book.noteConnected(machine:"Studio",address:"192.0.2.2",at:after))
        XCTAssertTrue(book.rename(shown,friendlyName:"After"))
        XCTAssertEqual(book.entries.first?.friendlyName,"After")
        XCTAssertEqual(book.entries.first?.lastAddress,"192.0.2.2")
        XCTAssertEqual(book.entries.first?.lastSeen,after)
    }

}
