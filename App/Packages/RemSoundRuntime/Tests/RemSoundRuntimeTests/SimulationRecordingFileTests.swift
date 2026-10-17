import Foundation
import XCTest
@testable import RemSoundRuntime
#if canImport(Darwin)
import Darwin

final class SimulationRecordingFileTests: XCTestCase {
    func folder() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("replay-file-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        return root
    }
    func testRegularUTF8FileIsReadAndSymlinkAndFIFORefuse() throws {
        let root=try folder();defer{try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("recording.txt");try Data("fixture\n".utf8).write(to:file)
        XCTAssertEqual(try SimulationRecordingFile.read(file),"fixture\n")
        let link=root.appendingPathComponent("link");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:file)
        XCTAssertThrowsError(try SimulationRecordingFile.read(link))
        let fifo=root.appendingPathComponent("pipe");XCTAssertEqual(mkfifo(fifo.path,0o600),0)
        XCTAssertThrowsError(try SimulationRecordingFile.read(fifo))
    }
    func testOversizedRegularFileRefusesBeforeDataAndLeavesInputIntact() throws {
        let root=try folder();defer{try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("large");XCTAssertTrue(FileManager.default.createFile(atPath:file.path,contents:nil))
        let handle=try FileHandle(forWritingTo:file);try handle.truncate(atOffset:UInt64(SimulationRecordingFile.maximumBytes+1));try handle.close()
        XCTAssertThrowsError(try SimulationRecordingFile.read(file))
        XCTAssertEqual(try file.resourceValues(forKeys:[.fileSizeKey]).fileSize,SimulationRecordingFile.maximumBytes+1)
    }
    func testChangedOrReplacedInputDefersWithoutAcceptingStaleBytes() throws {
        let root=try folder();defer{try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("recording");try Data("before".utf8).write(to:file)
        XCTAssertThrowsError(try SimulationRecordingFile.read(file,beforeFinal:{
            try Data("after!".utf8).write(to:file)
            try FileManager.default.setAttributes([.modificationDate:Date().addingTimeInterval(2)],ofItemAtPath:file.path)
        }))
        XCTAssertThrowsError(try SimulationRecordingFile.read(file,beforeFinal:{
            try FileManager.default.removeItem(at:file);try Data("replacement".utf8).write(to:file)
        }))
    }
}
#endif
