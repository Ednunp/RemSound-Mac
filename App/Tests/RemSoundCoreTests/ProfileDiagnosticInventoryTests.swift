import Darwin
import Foundation
import XCTest
@testable import RemSoundCore

final class ProfileDiagnosticInventoryTests: XCTestCase {
    private func root() throws -> URL {
        let r=URL(fileURLWithPath:try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:r,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at:r) };return r
    }
    private func profile(readOnly:Bool = false) -> ConnectionProfile {
        var p=ConnectionProfile(title:"private title",displayName:"private name",manualPeerAddress:"private address",selectedPeerAddresses:[],sendInput:false,receiveAudio:true,allowPlugins:false,reconnectOnOpen:false)
        p.readOnly=readOnly;return p
    }
    @discardableResult private func save(_ p:ConnectionProfile,_ root:URL) throws -> URL {
        let file=root.appendingPathComponent(p.id.uuidString+".json")
        try JSONEncoder().encode(p).write(to:file);return file
    }
    func testCountsValidLockedAndMalformedWithoutSavingOrExportingIdentity() throws {
        let r=try root();let a=try save(profile(),r),b=try save(profile(readOnly:true),r)
        let bad=r.appendingPathComponent(UUID().uuidString+".json");try Data("malformed private marker".utf8).write(to:bad)
        let before=try [a,b,bad].map { try Data(contentsOf:$0) }
        let result=try ProfileStore(directory:r).diagnosticInventory()
        XCTAssertEqual(result,.init(readable:2,readOnly:1,unreadable:1,deferred:0,complete:true))
        XCTAssertEqual(try [a,b,bad].map { try Data(contentsOf:$0) },before)
    }
    func testIgnoresHiddenAndNestedEntriesAndRefusesWrongIdentity() throws {
        let r=try root(),p=profile();try save(p,r)
        try JSONEncoder().encode(p).write(to:r.appendingPathComponent(UUID().uuidString+".json"))
        try Data("private ignored".utf8).write(to:r.appendingPathComponent(".hidden.json"))
        let nested=r.appendingPathComponent("nested");try FileManager.default.createDirectory(at:nested,withIntermediateDirectories:false);try save(profile(),nested)
        XCTAssertEqual(try ProfileStore(directory:r).diagnosticInventory(),.init(readable:1,readOnly:0,unreadable:1,deferred:0,complete:true))
    }
    func testOversizedFileIsDeferredBeforeDecode() throws {
        let r=try root(),p=r.appendingPathComponent(UUID().uuidString+".json")
        try Data(repeating:32,count:2*1024*1024+1).write(to:p)
        XCTAssertEqual(try ProfileStore(directory:r).diagnosticInventory(),.init(readable:0,readOnly:0,unreadable:0,deferred:1,complete:false))
    }
    func testReadVisitLimitReturnsIncompleteCounts() throws {
        let r=try root()
        for _ in 0..<257 { try Data("bad".utf8).write(to:r.appendingPathComponent(UUID().uuidString+".json")) }
        XCTAssertEqual(try ProfileStore(directory:r).diagnosticInventory(),.init(readable:0,readOnly:0,unreadable:256,deferred:1,complete:false))
    }
    func testChangedFileAndReplacedNameAreDeferred() throws {
        let r=try root(),file=try save(profile(),r)
        var calls=0
        let changed=try ProfileStore(directory:r).diagnosticInventory(afterRead:{ url in calls+=1;do { try Data("changed".utf8).write(to:url) } catch { XCTFail("Fixture write failed") } })
        XCTAssertEqual(calls,1);XCTAssertEqual(changed,.init(readable:0,readOnly:0,unreadable:0,deferred:1,complete:false))
        try JSONEncoder().encode(profile()).write(to:file)
        let replaced=try ProfileStore(directory:r).diagnosticInventory(afterRead:{ url in do { try FileManager.default.removeItem(at:url);try Data("replacement".utf8).write(to:url) } catch { XCTFail("Fixture replacement failed") } })
        XCTAssertEqual(replaced.deferred,1);XCTAssertFalse(replaced.complete)
    }
    func testSymlinkFileAndAncestorNeverReadTheTargetOrCreateFolders() throws {
        let r=try root(),target=try save(profile(),r)
        let folder=r.appendingPathComponent("store");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
        let link=folder.appendingPathComponent(UUID().uuidString+".json");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:target)
        let before=try Data(contentsOf:target)
        XCTAssertEqual(try ProfileStore(directory:folder).diagnosticInventory().unreadable,1)
        let ancestor=r.appendingPathComponent("link");try FileManager.default.createSymbolicLink(at:ancestor,withDestinationURL:folder)
        XCTAssertThrowsError(try ProfileStore(directory:ancestor.appendingPathComponent("missing")).diagnosticInventory())
        XCTAssertEqual(try Data(contentsOf:target),before)
        XCTAssertFalse(FileManager.default.fileExists(atPath:folder.appendingPathComponent("missing").path))
    }
    func testMissingDirectoryReturnsEmptyWithoutCreationAndRejectsNonFileURL() throws {
        let r=try root().appendingPathComponent("missing")
        XCTAssertEqual(try ProfileStore(directory:r).diagnosticInventory(),.init(readable:0,readOnly:0,unreadable:0,deferred:0,complete:true))
        XCTAssertFalse(FileManager.default.fileExists(atPath:r.path))
        XCTAssertThrowsError(try ProfileStore(directory:URL(string:"https://invalid.test/profiles")!).diagnosticInventory())
    }
    func testChangedReadsStillConsumeTheSharedByteBudget() throws {
        let r=try root()
        for _ in 0..<10 {
            let p=profile();var data=try JSONEncoder().encode(p)
            data.append(Data(repeating:32,count:2*1024*1024-data.count))
            try data.write(to:r.appendingPathComponent(p.id.uuidString+".json"))
        }
        var calls=0
        let result=try ProfileStore(directory:r).diagnosticInventory(afterRead:{ url in calls+=1;do { try Data("changed".utf8).write(to:url) } catch { XCTFail("Fixture mutation failed") } })
        XCTAssertEqual(calls,7)
        XCTAssertEqual(result,.init(readable:0,readOnly:0,unreadable:0,deferred:10,complete:false))
    }
    func testJSONDepthIsDeferredAndMalformedSyntaxIsUnusable() throws {
        let r=try root(),p=profile();var fields=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(p)) as? [String:Any])
        var nested:Any=0
        for _ in 0..<65 { nested=[nested] }
        fields["unknown bounded field"]=nested
        try JSONSerialization.data(withJSONObject:fields).write(to:r.appendingPathComponent(p.id.uuidString+".json"))
        try Data("{unterminated".utf8).write(to:r.appendingPathComponent(UUID().uuidString+".json"))
        XCTAssertEqual(try ProfileStore(directory:r).diagnosticInventory(),.init(readable:0,readOnly:0,unreadable:1,deferred:1,complete:false))
    }
    func testDirectoryEntryCapIsExplicitWithoutReadingOtherFiles() throws {
        let r=try root()
        for i in 0..<4097 { try Data().write(to:r.appendingPathComponent("entry\(i).txt")) }
        XCTAssertEqual(try ProfileStore(directory:r).diagnosticInventory(),.init(readable:0,readOnly:0,unreadable:0,deferred:0,complete:false))
    }
    func testFiniteChurnDoesNotRetainNativeDescriptors() throws {
        let r=try root();try save(profile(),r)
        try Data("bad".utf8).write(to:r.appendingPathComponent(UUID().uuidString+".json"))
        let store=ProfileStore(directory:r);_ = try store.diagnosticInventory()
        func descriptors() -> Int { (0..<256).reduce(0) { $0 + (fcntl(Int32($1),F_GETFD) >= 0 ? 1 : 0) } }
        let before=descriptors();XCTAssertLessThan(before,128)
        for _ in 0..<32 { XCTAssertEqual(try store.diagnosticInventory().readable,1) }
        XCTAssertEqual(descriptors(),before)
    }
}
