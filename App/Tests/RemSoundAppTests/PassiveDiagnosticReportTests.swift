import Foundation
import RemSoundCore
import XCTest
@testable import RemSoundApp

final class PassiveDiagnosticReportTests: XCTestCase {
    private func output(_ profiles:ProfileDiagnosticInventory? = nil,_ devices:AudioDeviceReportSnapshot? = nil) throws -> String {
        try PassiveDiagnosticReport.output(version:"version\nsecond",system:"system\u{2028}line",architecture:"arm64",profiles:profiles,devices:devices)
    }
    func testMissingCollectionIsExplicitAndHeadersAreSingleLine() throws {
        let text=try output()
        XCTAssertTrue(text.contains("Version: version second\n"));XCTAssertTrue(text.contains("System: system line\n"))
        XCTAssertTrue(text.contains("Profiles: not collected."));XCTAssertTrue(text.contains("Devices: not collected."))
        XCTAssertTrue(text.contains("not a supported-route or live audio test"))
    }
    func testProfileCountsAndStreamValuesDoNotExportPrivateDeviceStrings() throws {
        let item=AudioDeviceReportItem(uid:"private UID marker",name:"private name marker",isDefault:true,formats:[.init(sampleRate:48000,channels:2,bitsPerChannel:32,encoding:"private encoding marker"),nil])
        let text=try output(.init(readable:2,readOnly:1,unreadable:1,deferred:0,complete:true),.init(inputs:[item],outputs:[]))
        XCTAssertTrue(text.contains("2 readable, 1 read-only, 1 unreadable"));XCTAssertTrue(text.contains("[default]"))
        XCTAssertTrue(text.contains("48000.0 Hz, 2 channels, 32-bit"));XCTAssertTrue(text.contains("format unavailable"))
        XCTAssertFalse(text.contains("private UID marker"));XCTAssertFalse(text.contains("private name marker"));XCTAssertFalse(text.contains("private encoding marker"))
    }
    func testInvalidCountValuesRefuseBeforeReturningAReport() {
        for counts in [ProfileDiagnosticInventory(readable:-1,readOnly:0,unreadable:0,deferred:0,complete:true),
            .init(readable:Int.max,readOnly:0,unreadable:0,deferred:0,complete:true),
            .init(readable:1,readOnly:2,unreadable:0,deferred:0,complete:true),
            .init(readable:0,readOnly:0,unreadable:0,deferred:1,complete:true)] {
            XCTAssertThrowsError(try output(counts))
        }
    }
    func testInvalidOrExcessiveDeviceValuesRefuseBeforeReturningAReport() {
        let bad=AudioDeviceReportItem(uid:"ignored",name:"ignored",isDefault:false,formats:[.init(sampleRate:.nan,channels:2,bitsPerChannel:32,encoding:"ignored")])
        XCTAssertThrowsError(try output(nil,.init(inputs:[bad],outputs:[])))
        XCTAssertThrowsError(try output(nil,.init(inputs:Array(repeating:bad,count:1025),outputs:[])))
        let tooMany=AudioDeviceReportItem(uid:"ignored",name:"ignored",isDefault:false,formats:Array(repeating:nil,count:257))
        XCTAssertThrowsError(try output(nil,.init(inputs:[tooMany],outputs:[])))
    }
    func testIncompleteInventoryAndCompleteOutputByteCapAreTruthful() throws {
        let text=try output(.init(readable:1,readOnly:0,unreadable:0,deferred:1,complete:false))
        XCTAssertTrue(text.contains("Profile scan: incomplete"))
        let format=AudioDeviceReportFormat(sampleRate:48000,channels:2,bitsPerChannel:32,encoding:"ignored")
        let item=AudioDeviceReportItem(uid:"ignored",name:"ignored",isDefault:false,formats:Array(repeating:format,count:256))
        XCTAssertThrowsError(try output(nil,.init(inputs:Array(repeating:item,count:128),outputs:[]))) { error in
            guard case PassiveDiagnosticReport.Failure.tooLarge = error else { return XCTFail("Wrong cap failure") }
        }
    }
}
