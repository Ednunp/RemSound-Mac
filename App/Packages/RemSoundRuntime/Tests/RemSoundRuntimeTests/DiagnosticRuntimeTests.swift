import Foundation
import XCTest
@testable import RemSoundRuntime

#if canImport(Darwin)
final class DiagnosticRuntimeTests: XCTestCase {
    private func root() throws -> URL {
        let url=URL(fileURLWithPath:try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at:url) };return url
    }
    func testMetadataPreservesMalformedSettingsAndNeverReadsTheirValues() throws {
        let r=try root(),file=r.appendingPathComponent("settings.plist")
        let data=Data("malformed credential marker preserved".utf8);try data.write(to:file);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        let logs=r.appendingPathComponent("Logs");try FileManager.default.createDirectory(at:logs,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        try Data("private log line".utf8).write(to:logs.appendingPathComponent("private-name.log"))
        let result=try DiagnosticRuntimeMetadata.collect(root:r)
        XCTAssertEqual(result.settings,.present);XCTAssertEqual(result.settingsBytes,Int64(data.count));XCTAssertEqual(result.logFiles,1)
        XCTAssertEqual(try Data(contentsOf:file),data)
    }
    func testMissingPrivateRootCreatesNothingAndNormalValuesAreNotInspected() throws {
        let r=try root(),missing=r.appendingPathComponent("missing")
        XCTAssertEqual(try DiagnosticRuntimeMetadata.collect(root:missing).settings,.missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath:missing.path))
        XCTAssertEqual(try DiagnosticRuntimeMetadata.collect(root:nil,normalLogs:r).settings,.notInspected)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:r.path).isEmpty)
    }
    func testUnsafeRootAndSymlinkLogNeverFallBackOrReadTarget() throws {
        let r=try root();try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:r.path)
        XCTAssertThrowsError(try DiagnosticRuntimeMetadata.collect(root:r))
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:r.path)
        let logs=r.appendingPathComponent("Logs");try FileManager.default.createDirectory(at:logs,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let target=r.appendingPathComponent("target");try Data("private bytes".utf8).write(to:target)
        try FileManager.default.createSymbolicLink(at:logs.appendingPathComponent("link.log"),withDestinationURL:target)
        let result=try DiagnosticRuntimeMetadata.collect(root:r);XCTAssertEqual(result.logFiles,0);XCTAssertFalse(result.logsComplete)
        XCTAssertEqual(try Data(contentsOf:target),Data("private bytes".utf8))
    }
    func testChangingLogIsDeferredAndLimitsRemainExplicit() throws {
        let r=try root(),logs=r.appendingPathComponent("Logs");try FileManager.default.createDirectory(at:logs,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let file=logs.appendingPathComponent("one.log");try Data("old".utf8).write(to:file)
        let result=try DiagnosticRuntimeMetadata.collect(root:r,normalLogs:r,afterLogScan:{ do { try Data("changed log".utf8).write(to:file) } catch { XCTFail("Fixture failed") } })
        XCTAssertEqual(result.logFiles,0);XCTAssertFalse(result.logsComplete)
        try FileManager.default.removeItem(at:file)
        for i in 0..<1025 { try Data().write(to:logs.appendingPathComponent("entry\(i).log")) }
        let limited=try DiagnosticRuntimeMetadata.collect(root:r);XCTAssertEqual(limited.logFiles,1024);XCTAssertFalse(limited.logsComplete)
    }
    func testPublicationIsPrivateCompleteAndCannotReplaceAnExistingFile() throws {
        let r=try root(),target=r.appendingPathComponent("report.txt")
        XCTAssertEqual(try DiagnosticReportFile.publish("complete report\n",to:target),.published)
        XCTAssertEqual(try String(contentsOf:target),"complete report\n")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:target.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
        XCTAssertThrowsError(try DiagnosticReportFile.publish("replacement",to:target))
        XCTAssertEqual(try String(contentsOf:target),"complete report\n")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:r.path),["report.txt"])
    }
    func testConcurrentDestinationCreationIsPreservedAndStageIsRemoved() throws {
        let r=try root(),target=r.appendingPathComponent("report.txt")
        XCTAssertThrowsError(try DiagnosticReportFile.publish("report",to:target,beforePublish:{ do { try Data("prior".utf8).write(to:target) } catch { XCTFail("Fixture failed") } }))
        XCTAssertEqual(try Data(contentsOf:target),Data("prior".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:r.path),["report.txt"])
    }
    func testPublicationRefusesSymlinkParentMissingFolderAndOversizedReport() throws {
        let r=try root(),real=r.appendingPathComponent("real");try FileManager.default.createDirectory(at:real,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let link=r.appendingPathComponent("link");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:real)
        XCTAssertThrowsError(try DiagnosticReportFile.publish("report",to:link.appendingPathComponent("report.txt")))
        let missing=r.appendingPathComponent("missing/report.txt");XCTAssertThrowsError(try DiagnosticReportFile.publish("report",to:missing))
        XCTAssertThrowsError(try DiagnosticReportFile.publish(String(repeating:"x",count:256*1024+1),to:real.appendingPathComponent("big.txt")))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:real.path).isEmpty)
    }
    func testStageReplacementIsRefusedWithoutDeletingTheReplacement() throws {
        let r=try root(),target=r.appendingPathComponent("report.txt")
        var replacement: URL?
        XCTAssertThrowsError(try DiagnosticReportFile.publish("report",to:target,beforePublish:{
            do {
                let name=try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath:r.path).first)
                let stage=r.appendingPathComponent(name);replacement=stage
                try FileManager.default.removeItem(at:stage)
                try Data("external replacement".utf8).write(to:stage)
            } catch { XCTFail("Fixture failed") }
        }))
        XCTAssertFalse(FileManager.default.fileExists(atPath:target.path))
        XCTAssertEqual(try Data(contentsOf:try XCTUnwrap(replacement)),Data("external replacement".utf8))
    }
    func testMovedParentRefusesPublicationAndCleansOnlyItsHeldStage() throws {
        let r=try root(),parent=r.appendingPathComponent("parent"),moved=r.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        XCTAssertThrowsError(try DiagnosticReportFile.publish("report",to:parent.appendingPathComponent("report.txt"),beforePublish:{
            do {
                try FileManager.default.moveItem(at:parent,to:moved)
                try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
                try Data("existing".utf8).write(to:parent.appendingPathComponent("report.txt"))
            } catch { XCTFail("Fixture failed") }
        }))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:moved.path).isEmpty)
        XCTAssertEqual(try Data(contentsOf:parent.appendingPathComponent("report.txt")),Data("existing".utf8))
    }
}
#endif
